require "fileutils"
require "json"
require "time"

require_relative "../tempest"
require_relative "account_paths"
require_relative "post"
require_relative "facet"

module Tempest
  # Persists the home timeline snapshot so a restarted tempest can show the
  # last-seen posts before the network is even reachable. Stored alongside
  # session.json / cursor.json under XDG_CONFIG_HOME.
  #
  # Callers pass posts in chronological order (oldest first, newest last); the
  # store keeps only the most recent MAX_POSTS to bound disk usage.
  class TimelineStore
    MAX_POSTS = 50

    def self.default_path(env = ENV)
      Tempest::AccountPaths.legacy_timeline_path(env)
    end

    def self.for(env = ENV, did:)
      new(path: Tempest::AccountPaths.timeline_path(env, did: did))
    end

    def initialize(path:)
      @path = path
    end

    attr_reader :path

    def save(posts:, at: Time.now)
      payload = {
        "posts" => posts.last(MAX_POSTS).map { |p| serialize_post(p) },
        "saved_at" => at.utc.iso8601(6),
      }

      FileUtils.mkdir_p(File.dirname(@path), mode: 0o700)
      File.open(@path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |io|
        io.write(JSON.generate(payload))
      end
    end

    def load
      return nil unless File.exist?(@path)

      data = JSON.parse(File.read(@path))
      return nil unless data.is_a?(Hash) && data["posts"].is_a?(Array) && data["saved_at"]

      {
        posts: data["posts"].map { |hash| deserialize_post(hash) },
        saved_at: Time.iso8601(data["saved_at"]),
      }
    rescue JSON::ParserError, ArgumentError
      nil
    end

    private

    def serialize_post(post)
      {
        "uri" => post.uri,
        "cid" => post.cid,
        "handle" => post.handle,
        "display_name" => post.display_name,
        "text" => post.text,
        "created_at" => post.created_at,
        "facets" => post.facets.map { |f| serialize_facet(f) },
        "reply_parent_uri" => post.reply_parent_uri,
      }
    end

    def deserialize_post(hash)
      Post.new(
        uri: hash["uri"],
        cid: hash["cid"],
        handle: hash["handle"],
        display_name: hash["display_name"],
        text: hash["text"],
        created_at: hash["created_at"],
        facets: deserialize_facets(hash["facets"]),
        reply_parent_uri: hash["reply_parent_uri"],
      )
    end

    def serialize_facet(facet)
      {
        "byte_start" => facet.byte_start,
        "byte_end" => facet.byte_end,
        "uri" => facet.uri,
      }
    end

    def deserialize_facets(raw)
      return [] unless raw.is_a?(Array)
      raw.filter_map do |hash|
        next nil unless hash.is_a?(Hash)
        byte_start = hash["byte_start"]
        byte_end = hash["byte_end"]
        uri = hash["uri"]
        next nil unless byte_start.is_a?(Integer) && byte_end.is_a?(Integer) && uri.is_a?(String)
        Facet::Link.new(byte_start: byte_start, byte_end: byte_end, uri: uri)
      end
    end
  end
end
