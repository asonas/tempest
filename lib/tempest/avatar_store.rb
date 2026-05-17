require "fileutils"
require "json"
require "net/http"
require "open3"
require "tmpdir"
require "uri"

require_relative "../tempest"

module Tempest
  # Resolves Bluesky DIDs to a local PNG file path for the actor's avatar.
  # Mirrors the shape of HandleResolver: an injected client speaks XRPC for
  # `app.bsky.actor.getProfile`, and the result is cached in-process so the
  # PDS isn't hit on every event.
  #
  # Disk layout: avatars live under `cache_dir/` as
  # "<sanitized-did>__<avatar-cid>.png". The avatar CID is read from the
  # tail of the avatar URL so that re-uploaded avatars (which receive a new
  # CID) invalidate the cache without server-side coordination.
  class AvatarStore
    # Sentinel for "we tried, there is no avatar" — distinct from "we haven't
    # looked yet" (nil). Mirrors the pattern in HandleResolver.
    NOT_FOUND = Object.new.freeze

    # Standalone profile client used by Tempest::CLI.
    #
    # AvatarStore resolves DIDs on a background thread, so the client it uses
    # must be thread-safe. We deliberately do NOT use Tempest::XRPCClient
    # here, because the underlying Tempest::HTTP layer is built on
    # Async::HTTP::Internet whose Fibers cannot be resumed from a thread other
    # than the one that created them — calling it from our worker yields
    # `FiberError: fiber called across threads`.
    #
    # app.bsky.actor.getProfile is served unauthenticated by
    # public.api.bsky.app, so we don't need a session here.
    class DefaultProfileClient
      HOST = "https://public.api.bsky.app".freeze

      def get(nsid, query: nil)
        uri = URI("#{HOST}/xrpc/#{nsid}")
        uri.query = URI.encode_www_form(query) if query && !query.empty?
        res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
          http.get(uri.request_uri, "Accept" => "application/json")
        end
        raise Tempest::APIError.new(res.code.to_i, { "error" => res.message }) unless res.is_a?(Net::HTTPSuccess)
        JSON.parse(res.body)
      end
    end

    def initialize(client:, cache_dir:, fetcher: nil, converter: nil, async: true, executor: nil)
      @client = client
      @cache_dir = cache_dir
      @fetcher = fetcher || self.class.default_fetcher
      @converter = converter || self.class.default_converter
      @async = async
      @executor = executor || method(:default_executor)
      @cache = {}
      @pending = {}
      @mutex = Mutex.new
      FileUtils.mkdir_p(@cache_dir)
    end

    # Production HTTP fetcher used when no fetcher is injected. Returns the
    # raw bytes and Content-Type header so the converter can pick the right
    # input format.
    def self.default_fetcher
      @default_fetcher ||= lambda do |url|
        uri = URI(url)
        res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
          http.get(uri.request_uri)
        end
        unless res.is_a?(Net::HTTPSuccess)
          raise Tempest::APIError.new(res.code.to_i, { "error" => res.message })
        end
        [res.body, res["content-type"].to_s]
      end
    end

    # Production format normalizer: shells out to ImageMagick to crop-fit the
    # avatar into a 128x128 PNG. The crop pads non-square inputs so the Kitty
    # graphics protocol can render at a consistent 1-row, 2-col aspect.
    def self.default_converter
      @default_converter ||= lambda do |bytes, content_type:|
        ext = ext_for(content_type, bytes)
        Dir.mktmpdir do |dir|
          src = File.join(dir, "src.#{ext}")
          dst = File.join(dir, "out.png")
          File.binwrite(src, bytes)
          _out, status = Open3.capture2e(
            "magick", src,
            "-resize", "128x128^",
            "-gravity", "center",
            "-extent", "128x128",
            dst,
          )
          raise "magick convert failed" unless status.success?
          File.binread(dst)
        end
      end
    end

    EXT_BY_MIME = {
      "image/jpeg" => "jpg",
      "image/jpg" => "jpg",
      "image/png" => "png",
      "image/webp" => "webp",
      "image/gif" => "gif",
      "image/avif" => "avif",
    }.freeze

    def self.ext_for(content_type, bytes)
      mime = content_type.to_s.split(";").first.to_s.strip.downcase
      return EXT_BY_MIME[mime] if EXT_BY_MIME.key?(mime)
      head = bytes.byteslice(0, 16).to_s
      return "jpg"  if head.start_with?("\xFF\xD8\xFF".b)
      return "png"  if head.start_with?("\x89PNG\r\n\x1A\n".b)
      return "gif"  if head.start_with?("GIF87a", "GIF89a")
      return "webp" if head[0, 4] == "RIFF" && head[8, 4] == "WEBP"
      "bin"
    end

    def path_for(did)
      cached = @mutex.synchronize { @cache[did] }
      return cached_value(cached) unless cached.nil?

      if @async
        enqueue_resolve(did)
        nil
      else
        resolve_and_cache(did)
      end
    end

    def seed(did, path)
      @mutex.synchronize { @cache[did] = path }
    end

    private

    def cached_value(value)
      value.equal?(NOT_FOUND) ? nil : value
    end

    def resolve_and_cache(did)
      path = resolve_sync(did)
      @mutex.synchronize { @cache[did] = path.nil? ? NOT_FOUND : path }
      path
    end

    def enqueue_resolve(did)
      should_dispatch = @mutex.synchronize do
        next false if @pending[did]
        @pending[did] = true
        true
      end
      return unless should_dispatch

      @executor.call do
        begin
          resolve_and_cache(did)
        ensure
          @mutex.synchronize { @pending.delete(did) }
        end
      end
    end

    def default_executor(&block)
      Thread.new(&block)
    end

    def resolve_sync(did)
      profile = @client.get("app.bsky.actor.getProfile", query: { "actor" => did })
      avatar_url = profile.is_a?(Hash) ? profile["avatar"] : nil
      return nil if avatar_url.nil? || avatar_url.empty?

      bytes, content_type = @fetcher.call(avatar_url)
      png = @converter.call(bytes, content_type: content_type)
      cid = File.basename(URI(avatar_url).path)
      path = File.join(@cache_dir, "#{sanitize(did)}__#{cid}.png")
      File.binwrite(path, png)
      path
    rescue Tempest::APIError, StandardError
      nil
    end

    def sanitize(did)
      did.gsub(/[^A-Za-z0-9._-]/, "_")
    end
  end
end
