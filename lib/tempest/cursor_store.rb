require "fileutils"
require "json"
require "time"

require_relative "../tempest"

module Tempest
  # Persists the last-seen Jetstream `time_us` so a restarted tempest can hand
  # the server a cursor and replay events from the previous session. Stored
  # alongside session.json under XDG_CONFIG_HOME. Staleness is decided by the
  # caller (StreamManager checks saved_at against its replay window).
  class CursorStore
    def self.default_path(env = ENV)
      explicit = env["TEMPEST_CURSOR_PATH"]
      return explicit if explicit && !explicit.empty?

      base = env["XDG_CONFIG_HOME"]
      base = File.join(env["HOME"].to_s, ".config") if base.nil? || base.empty?
      File.join(base, "tempest", "cursor.json")
    end

    def initialize(path:)
      @path = path
    end

    attr_reader :path

    def save(time_us:, at: Time.now)
      payload = { "time_us" => time_us, "saved_at" => at.utc.iso8601(6) }

      FileUtils.mkdir_p(File.dirname(@path))
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
