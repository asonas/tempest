require "logger"
require "fileutils"
require "time"

module Tempest
  # Structured diagnostic logging for tempest.
  #
  # `Tempest::DebugLog.build` returns a `Channel` that fans messages out to one
  # or more underlying `::Logger` instances. The format is logfmt-flavored
  # single-line:
  #
  #   2026-05-18T01:23:45+09:00 level=warn module=watchdog event=stalled_detected elapsed_seconds=612.3 threshold_seconds=600
  #
  # The fixed leading keys (`level=`, `module=`, `event=`) are produced by the
  # formatter from the level + progname + first-positional arguments, so call
  # sites just write the variable fields as keyword arguments:
  #
  #   @logger.warn("watchdog", event: "stalled_detected", elapsed_seconds: 612.3, threshold_seconds: 600)
  #
  # Output destinations:
  #
  #   * `info.log` — INFO and above, always written when logging is enabled.
  #   * `debug.log` — DEBUG and above, written only when `--debug` (or the
  #     equivalent flag passed to `build(debug: true)`) is on.
  #
  # Default base directory is `$XDG_STATE_HOME/tempest` (falling back to
  # `~/.local/state/tempest`). Override via `TEMPEST_LOG_DIR=/path` for the
  # whole tree, or set `TEMPEST_NO_LOG=1` to disable both files entirely (used
  # by tests). The legacy `TEMPEST_DEBUG_LOG=/path/to/file` env var still
  # works and routes everything (DEBUG and above) to a single file regardless
  # of the other settings.
  #
  # All file destinations use size-based rotation (5 MiB x 5 files) so a
  # long-running session can't fill the disk.
  module DebugLog
    LEVELS = {
      "DEBUG" => Logger::DEBUG,
      "INFO"  => Logger::INFO,
      "WARN"  => Logger::WARN,
      "ERROR" => Logger::ERROR,
      "FATAL" => Logger::FATAL,
    }.freeze

    DEFAULT_ROTATION_COUNT = 5
    DEFAULT_ROTATION_SIZE = 5 * 1024 * 1024

    module_function

    def build(env:, debug: false)
      loggers = []

      legacy = env["TEMPEST_DEBUG_LOG"]
      if legacy && !legacy.empty?
        loggers << build_file_logger(legacy, level: resolve_level(env["TEMPEST_DEBUG_LOG_LEVEL"]) || Logger::DEBUG)
      end

      unless env["TEMPEST_NO_LOG"] == "1"
        dir = log_dir(env)
        loggers << build_file_logger(File.join(dir, "info.log"), level: Logger::INFO)
        loggers << build_file_logger(File.join(dir, "debug.log"), level: Logger::DEBUG) if debug
      end

      Channel.new(loggers: loggers)
    end

    def null_channel
      Channel.new(loggers: [])
    end

    def formatter
      proc do |severity, time, progname, msg|
        parts = []
        parts << "level=#{severity.downcase}"
        parts << "module=#{progname}" if progname && !progname.to_s.empty?
        parts << msg if msg && !msg.to_s.empty?
        "#{time.iso8601} #{parts.join(' ')}\n"
      end
    end

    def resolve_level(value)
      return nil if value.nil? || value.empty?
      LEVELS[value.to_s.upcase]
    end

    def log_dir(env)
      override = env["TEMPEST_LOG_DIR"]
      return override if override && !override.empty?

      xdg = env["XDG_STATE_HOME"]
      base = if xdg && !xdg.empty?
        xdg
      else
        File.join(env["HOME"] || Dir.home, ".local", "state")
      end
      File.join(base, "tempest")
    end

    def build_file_logger(path, level:)
      path = File.expand_path(path)
      FileUtils.mkdir_p(File.dirname(path))
      logger = Logger.new(path, DEFAULT_ROTATION_COUNT, DEFAULT_ROTATION_SIZE)
      logger.level = level
      logger.formatter = formatter
      logger
    end

    def encode_value(value)
      case value
      when nil
        "nil"
      when true, false, Integer, Float, Symbol
        value.to_s
      when Time
        value.iso8601
      else
        s = value.to_s
        if s.empty?
          '""'
        elsif s.match?(/[\s"=]/)
          '"' + s.gsub('\\', '\\\\\\\\').gsub('"', '\\"') + '"'
        else
          s
        end
      end
    end

    class Channel
      attr_reader :loggers

      def initialize(loggers:, defaults: {})
        @loggers = Array(loggers)
        @defaults = defaults.freeze
      end

      def info(mod, event:, **fields)
        emit(Logger::INFO, mod, event, fields)
      end

      def debug(mod, event:, **fields)
        emit(Logger::DEBUG, mod, event, fields)
      end

      def warn(mod, event:, **fields)
        emit(Logger::WARN, mod, event, fields)
      end

      def error(mod, event:, **fields)
        emit(Logger::ERROR, mod, event, fields)
      end

      # Returns a child channel that prepends `default_fields` to every
      # subsequent log call. Used to attach per-session context such as `did=`
      # to long-lived components (StreamManager, Watchdog) without sprinkling
      # the field across every call site.
      def with(**default_fields)
        return self if default_fields.empty?
        Channel.new(loggers: @loggers, defaults: @defaults.merge(default_fields))
      end

      def close
        @loggers.each do |logger|
          begin
            logger.close
          rescue StandardError
            # Best-effort: a half-built or already-closed logger should not
            # take down shutdown.
          end
        end
      end

      private

      def emit(level, mod, event, fields)
        return if @loggers.empty?
        merged = @defaults.merge(fields)
        msg = format_body(event, merged)
        @loggers.each { |logger| logger.add(level, msg, mod) }
      end

      def format_body(event, fields)
        parts = []
        parts << "event=#{Tempest::DebugLog.encode_value(event)}" if event
        fields.each do |k, v|
          parts << "#{k}=#{Tempest::DebugLog.encode_value(v)}"
        end
        parts.join(" ")
      end
    end
  end
end
