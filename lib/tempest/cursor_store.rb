require "fileutils"
require "json"
require "time"

require_relative "../tempest"
require_relative "account_paths"

module Tempest
  # Persists the last-seen Jetstream `time_us` so a restarted tempest can hand
  # the server a cursor and replay events from the previous session. Stored
  # alongside session.json under XDG_CONFIG_HOME. Staleness is decided by the
  # caller (StreamManager checks saved_at against its replay window).
  class CursorStore
    def self.default_path(env = ENV)
      Tempest::AccountPaths.legacy_cursor_path(env)
    end

    def self.for(env = ENV, did:)
      new(path: Tempest::AccountPaths.cursor_path(env, did: did))
    end

    def initialize(path:)
      @path = path
    end

    attr_reader :path

    def save(time_us:, at: Time.now)
      payload = { "time_us" => time_us, "saved_at" => at.utc.iso8601(6) }

      FileUtils.mkdir_p(File.dirname(@path), mode: 0o700)
      File.open(@path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |io|
        io.write(JSON.generate(payload))
      end
    end

    def load
      return nil unless File.exist?(@path)

      data = JSON.parse(File.read(@path))
      return nil unless data.is_a?(Hash) && data["time_us"] && data["saved_at"]

      { time_us: data["time_us"], saved_at: Time.iso8601(data["saved_at"]) }
    rescue JSON::ParserError, ArgumentError
      nil
    end

    def clear
      File.delete(@path) if File.exist?(@path)
    end
  end
end
