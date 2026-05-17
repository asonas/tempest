require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "logger"
require "tempest/debug_log"

class TestDebugLog < Minitest::Test
  def test_from_env_returns_null_logger_when_var_unset
    logger = Tempest::DebugLog.from_env({})

    # Should accept calls without raising or producing observable output.
    logger.info("[stream]") { "should be discarded" }
    logger.debug("nope")
    logger.warn("[watchdog]") { "still discarded" }
  end

  def test_from_env_returns_null_logger_when_var_empty
    logger = Tempest::DebugLog.from_env({ "TEMPEST_DEBUG_LOG" => "" })
    logger.info("[stream]") { "still discarded" }
  end

  def test_from_env_creates_file_when_path_given
    Dir.mktmpdir do |dir|
      path = File.join(dir, "debug.log")
      logger = Tempest::DebugLog.from_env({ "TEMPEST_DEBUG_LOG" => path })

      logger.info("stream") { "hello world" }
      logger.close if logger.respond_to?(:close)

      assert File.exist?(path), "log file should be created at #{path}"
      content = File.read(path)
      assert_match(/INFO/, content)
      assert_match(/\[stream\]/, content)
      assert_match(/hello world/, content)
    end
  end

  def test_from_env_creates_parent_directory_when_missing
    Dir.mktmpdir do |dir|
      nested = File.join(dir, "nested", "deeper", "debug.log")
      logger = Tempest::DebugLog.from_env({ "TEMPEST_DEBUG_LOG" => nested })

      logger.info("tag") { "msg" }
      logger.close if logger.respond_to?(:close)

      assert File.exist?(nested)
    end
  end

  def test_from_env_expands_tilde_in_path
    Dir.mktmpdir do |dir|
      orig_home = ENV["HOME"]
      ENV["HOME"] = dir
      begin
        logger = Tempest::DebugLog.from_env({ "TEMPEST_DEBUG_LOG" => "~/tempest-debug.log" })
        logger.info("tag") { "hi" }
        logger.close if logger.respond_to?(:close)

        assert File.exist?(File.join(dir, "tempest-debug.log"))
      ensure
        ENV["HOME"] = orig_home
      end
    end
  end

  def test_from_env_honors_level_override_debug
    Dir.mktmpdir do |dir|
      path = File.join(dir, "debug.log")
      logger = Tempest::DebugLog.from_env({
        "TEMPEST_DEBUG_LOG" => path,
        "TEMPEST_DEBUG_LOG_LEVEL" => "DEBUG",
      })

      logger.debug("tag") { "debug-line" }
      logger.close if logger.respond_to?(:close)

      assert_match(/debug-line/, File.read(path))
    end
  end

  def test_from_env_default_level_is_info_so_debug_is_suppressed
    Dir.mktmpdir do |dir|
      path = File.join(dir, "debug.log")
      logger = Tempest::DebugLog.from_env({ "TEMPEST_DEBUG_LOG" => path })

      logger.debug("tag") { "should-not-appear" }
      logger.info("tag") { "should-appear" }
      logger.close if logger.respond_to?(:close)

      content = File.read(path)
      refute_match(/should-not-appear/, content)
      assert_match(/should-appear/, content)
    end
  end

  def test_from_env_honors_level_override_warn
    Dir.mktmpdir do |dir|
      path = File.join(dir, "debug.log")
      logger = Tempest::DebugLog.from_env({
        "TEMPEST_DEBUG_LOG" => path,
        "TEMPEST_DEBUG_LOG_LEVEL" => "WARN",
      })

      logger.info("tag") { "info-suppressed" }
      logger.warn("tag") { "warn-shown" }
      logger.close if logger.respond_to?(:close)

      content = File.read(path)
      refute_match(/info-suppressed/, content)
      assert_match(/warn-shown/, content)
    end
  end

  def test_format_includes_iso8601_timestamp_and_tag
    Dir.mktmpdir do |dir|
      path = File.join(dir, "debug.log")
      logger = Tempest::DebugLog.from_env({ "TEMPEST_DEBUG_LOG" => path })

      logger.info("stream") { "subscribe cursor=nil" }
      logger.close if logger.respond_to?(:close)

      line = File.read(path).lines.find { |l| l.include?("subscribe cursor=nil") }
      refute_nil line, "expected log line to be present"
      assert_match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+\-]\d{2}:\d{2}/, line)
      assert_match(/INFO/, line)
      assert_match(/\[stream\]/, line)
      assert_match(/subscribe cursor=nil/, line)
    end
  end
end
