require "fileutils"
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

    def initialize(client:, cache_dir:, fetcher:, converter:, async: true, executor: nil)
      @client = client
      @cache_dir = cache_dir
      @fetcher = fetcher
      @converter = converter
      @async = async
      @executor = executor || method(:default_executor)
      @cache = {}
      @pending = {}
      @mutex = Mutex.new
      FileUtils.mkdir_p(@cache_dir)
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
