require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "logger"
require "stringio"
require "tempest/debug_log"

class TestDebugLog < Minitest::Test
  # ----- Channel formatting ------------------------------------------------

  def with_string_channel(level: Logger::DEBUG)
    io = StringIO.new
    logger = Logger.new(io)
    logger.level = level
    logger.formatter = Tempest::DebugLog.formatter
    channel = Tempest::DebugLog::Channel.new(loggers: [logger])
    yield channel, io
  ensure
    logger&.close
  end

  def test_format_uses_logfmt_with_required_keys
    with_string_channel do |channel, io|
      channel.info("stream", event: "subscribe", cursor: nil, attempt: 0)

      line = io.string.lines.find { |l| l.include?("event=subscribe") }
      refute_nil line, "expected an info line to be written"

      assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+\-]\d{2}:\d{2} /, line)
      assert_match(/\blevel=info\b/, line)
      assert_match(/\bmodule=stream\b/, line)
      assert_match(/\bevent=subscribe\b/, line)
      assert_match(/\bcursor=nil\b/, line)
      assert_match(/\battempt=0\b/, line)
    end
  end

  def test_format_quotes_values_with_whitespace_or_quotes
    with_string_channel do |channel, io|
      channel.warn("stream", event: "disconnect", error_message: 'oops "boom"')

      line = io.string.lines.first
      assert_match(/error_message="oops \\"boom\\""/, line)
    end
  end

  def test_format_renders_time_as_iso8601
    with_string_channel do |channel, io|
      t = Time.utc(2026, 5, 17, 12, 34, 56)
      channel.info("stream", event: "worker_start", last_event_at: t)
      line = io.string.lines.first
      assert_includes line, "last_event_at=2026-05-17T12:34:56Z"
    end
  end

  def test_format_renders_nil_as_literal_nil
    with_string_channel do |channel, io|
      channel.info("stream", event: "subscribe", cursor: nil)
      assert_match(/\bcursor=nil\b/, io.string)
    end
  end

  def test_format_renders_booleans
    with_string_channel do |channel, io|
      channel.debug("watchdog", event: "tick", running: true)
      assert_match(/\brunning=true\b/, io.string)
    end
  end

  def test_levels_route_to_correct_logger_severity
    with_string_channel do |channel, io|
      channel.debug("stream", event: "cursor_save", cursor: 42)
      channel.info("stream", event: "subscribe", cursor: 43)
      channel.warn("watchdog", event: "stalled_detected", elapsed_seconds: 612)
      channel.error("watchdog", event: "tick_error", error_class: "RuntimeError")

      content = io.string
      assert_match(/level=debug.*event=cursor_save/, content)
      assert_match(/level=info.*event=subscribe/, content)
      assert_match(/level=warn.*event=stalled_detected/, content)
      assert_match(/level=error.*event=tick_error/, content)
    end
  end

  # ----- Multi-channel routing --------------------------------------------

  def test_channel_writes_to_every_underlying_logger
    info_io = StringIO.new
    debug_io = StringIO.new
    info_logger = Logger.new(info_io)
    info_logger.level = Logger::INFO
    info_logger.formatter = Tempest::DebugLog.formatter
    debug_logger = Logger.new(debug_io)
    debug_logger.level = Logger::DEBUG
    debug_logger.formatter = Tempest::DebugLog.formatter

    channel = Tempest::DebugLog::Channel.new(loggers: [info_logger, debug_logger])

    channel.info("stream", event: "subscribe")
    channel.debug("stream", event: "cursor_save", cursor: 7)

    assert_match(/event=subscribe/, info_io.string)
    refute_match(/event=cursor_save/, info_io.string)

    assert_match(/event=subscribe/, debug_io.string)
    assert_match(/event=cursor_save/, debug_io.string)
  end

  # ----- Null channel ------------------------------------------------------

  def test_null_channel_swallows_calls
    channel = Tempest::DebugLog.null_channel
    channel.info("stream", event: "subscribe")
    channel.debug("stream", event: "cursor_save", cursor: 1)
    channel.warn("watchdog", event: "stalled_detected")
    channel.error("watchdog", event: "tick_error")
  end

  # ----- Builder -----------------------------------------------------------

  def test_build_returns_empty_channel_when_disabled_via_env
    channel = Tempest::DebugLog.build(env: { "TEMPEST_NO_LOG" => "1" })
    assert_kind_of Tempest::DebugLog::Channel, channel
    assert_empty channel.loggers
  end

  def test_build_creates_info_log_at_default_xdg_state_path
    Dir.mktmpdir do |home|
      env = { "HOME" => home }
      channel = Tempest::DebugLog.build(env: env)
      channel.info("stream", event: "subscribe", cursor: 1)
      channel.close

      info_path = File.join(home, ".local", "state", "tempest", "info.log")
      assert File.exist?(info_path), "expected info.log at #{info_path}"
      assert_match(/event=subscribe/, File.read(info_path))
    end
  end

  def test_build_honors_xdg_state_home
    Dir.mktmpdir do |base|
      env = { "XDG_STATE_HOME" => base, "HOME" => "/nonexistent" }
      channel = Tempest::DebugLog.build(env: env)
      channel.info("stream", event: "subscribe", cursor: 1)
      channel.close

      assert File.exist?(File.join(base, "tempest", "info.log"))
    end
  end

  def test_build_honors_tempest_log_dir
    Dir.mktmpdir do |dir|
      env = { "TEMPEST_LOG_DIR" => dir }
      channel = Tempest::DebugLog.build(env: env)
      channel.info("stream", event: "subscribe", cursor: 1)
      channel.close

      assert File.exist?(File.join(dir, "info.log"))
    end
  end

  def test_build_enables_debug_file_only_when_debug_flag_true
    Dir.mktmpdir do |dir|
      env = { "TEMPEST_LOG_DIR" => dir }
      channel = Tempest::DebugLog.build(env: env, debug: true)
      channel.info("stream", event: "subscribe", cursor: 1)
      channel.debug("stream", event: "cursor_save", cursor: 2)
      channel.close

      info_path = File.join(dir, "info.log")
      debug_path = File.join(dir, "debug.log")

      assert File.exist?(info_path)
      assert File.exist?(debug_path)

      info_content = File.read(info_path)
      debug_content = File.read(debug_path)

      assert_match(/event=subscribe/, info_content)
      refute_match(/event=cursor_save/, info_content)

      assert_match(/event=subscribe/, debug_content)
      assert_match(/event=cursor_save/, debug_content)
    end
  end

  def test_build_without_debug_flag_does_not_create_debug_log
    Dir.mktmpdir do |dir|
      env = { "TEMPEST_LOG_DIR" => dir }
      channel = Tempest::DebugLog.build(env: env)
      channel.info("stream", event: "subscribe", cursor: 1)
      channel.close

      refute File.exist?(File.join(dir, "debug.log"))
    end
  end

  def test_build_creates_parent_directories
    Dir.mktmpdir do |base|
      env = { "TEMPEST_LOG_DIR" => File.join(base, "nested", "deeper") }
      channel = Tempest::DebugLog.build(env: env)
      channel.info("stream", event: "subscribe")
      channel.close

      assert File.exist?(File.join(base, "nested", "deeper", "info.log"))
    end
  end

  def test_build_supports_legacy_single_file_path_env
    # Backward compat for callers (and tests) that pre-date the two-file scheme.
    # TEMPEST_NO_LOG=1 disables the default paths, but the legacy var still
    # wins for that one file.
    Dir.mktmpdir do |dir|
      path = File.join(dir, "combined.log")
      env = { "TEMPEST_DEBUG_LOG" => path, "TEMPEST_NO_LOG" => "1" }
      channel = Tempest::DebugLog.build(env: env)
      channel.info("stream", event: "subscribe", cursor: 1)
      channel.debug("stream", event: "cursor_save", cursor: 2)
      channel.close

      content = File.read(path)
      assert_match(/event=subscribe/, content)
      # Legacy mode defaults to DEBUG so existing diagnostic flows still work.
      assert_match(/event=cursor_save/, content)
    end
  end

  def test_build_uses_size_based_rotation_for_files
    Dir.mktmpdir do |dir|
      env = { "TEMPEST_LOG_DIR" => dir }
      channel = Tempest::DebugLog.build(env: env, debug: true)
      refute_empty channel.loggers
      channel.loggers.each do |logger|
        logdev = logger.instance_variable_get(:@logdev)
        refute_nil logdev, "expected log device on #{logger.inspect}"
        shift_size = logdev.instance_variable_get(:@shift_size).to_i
        assert_operator shift_size, :>, 0, "expected size-based rotation"
      end
      channel.close
    end
  end

  # ----- Channel#with context defaults --------------------------------------

  def test_with_prepends_default_fields_to_every_log_call
    with_string_channel do |channel, io|
      tagged = channel.with(did: "did:plc:abc")
      tagged.info("stream", event: "subscribe", cursor: nil)

      line = io.string.lines.find { |l| l.include?("event=subscribe") }
      refute_nil line
      assert_match(/\bdid=did:plc:abc\b/, line)
      assert_match(/\bcursor=nil\b/, line)
    end
  end

  def test_with_returns_self_when_no_fields_given
    with_string_channel do |channel, _io|
      assert_same channel, channel.with
    end
  end

  def test_with_does_not_mutate_parent_channel
    with_string_channel do |channel, io|
      channel.with(did: "did:plc:abc")
      channel.info("stream", event: "subscribe")

      line = io.string.lines.find { |l| l.include?("event=subscribe") }
      refute_match(/did=/, line)
    end
  end

  def test_with_chains_default_fields
    with_string_channel do |channel, io|
      base = channel.with(did: "did:plc:abc")
      base.with(component: "stream").info("stream", event: "live_resumed")

      line = io.string.lines.find { |l| l.include?("event=live_resumed") }
      assert_match(/\bdid=did:plc:abc\b/, line)
      assert_match(/\bcomponent=stream\b/, line)
    end
  end

  def test_explicit_field_overrides_default
    with_string_channel do |channel, io|
      tagged = channel.with(did: "did:plc:default")
      tagged.info("stream", event: "subscribe", did: "did:plc:override")

      line = io.string.lines.find { |l| l.include?("event=subscribe") }
      assert_match(/\bdid=did:plc:override\b/, line)
      refute_match(/did:plc:default/, line)
    end
  end
end
