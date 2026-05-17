require "logger"
require "fileutils"
require "time"

module Tempest
  # Thin wrapper around stdlib Logger for opt-in debug logging.
  #
  # Activated only when the TEMPEST_DEBUG_LOG environment variable points at a
  # writable path. Otherwise from_env returns a Logger pointed at IO::NULL at
  # FATAL level, so call sites can unconditionally call `info`/`debug`/`warn`
  # without an `if logger` guard and without producing any output or file I/O.
  #
  # Output format is ISO-8601 local time + level + progname tag + message, e.g.:
  #   2026-05-17T10:30:42+09:00 INFO  [stream] reconnect attempt=2 cursor=nil
  module DebugLog
    LEVELS = {
      "DEBUG" => Logger::DEBUG,
      "INFO"  => Logger::INFO,
      "WARN"  => Logger::WARN,
      "ERROR" => Logger::ERROR,
      "FATAL" => Logger::FATAL,
    }.freeze

    module_function

    def from_env(env)
      raw = env["TEMPEST_DEBUG_LOG"]
      if raw.nil? || raw.empty?
        return build_null_logger
      end

      path = File.expand_path(raw)
      FileUtils.mkdir_p(File.dirname(path))

      logger = Logger.new(path, "daily")
      logger.level = resolve_level(env["TEMPEST_DEBUG_LOG_LEVEL"]) || Logger::INFO
      logger.formatter = formatter
      logger
    end

    def build_null_logger
      logger = Logger.new(IO::NULL)
      logger.level = Logger::FATAL
      logger
    end

    def formatter
      proc do |severity, time, progname, msg|
        tag = progname && !progname.to_s.empty? ? "[#{progname}] " : ""
        "#{time.iso8601} #{severity.ljust(5)} #{tag}#{msg}\n"
      end
    end

    def resolve_level(value)
      return nil if value.nil? || value.empty?
      LEVELS[value.to_s.upcase]
    end
  end
end
