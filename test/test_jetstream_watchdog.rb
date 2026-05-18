require_relative "test_helper"
require "logger"
require "tempest/debug_log"
require "tempest/jetstream/watchdog"

class TestJetstreamWatchdog < Minitest::Test
  # Minimal fake collaborator that exposes only the surface the watchdog uses.
  class FakeStreamManager
    attr_reader :force_reconnect_calls
    attr_accessor :last_event_at, :running

    def initialize(last_event_at:, running: true)
      @last_event_at = last_event_at
      @running = running
      @force_reconnect_calls = 0
      @mutex = Mutex.new
    end

    def running?
      @running
    end

    def force_reconnect
      @mutex.synchronize { @force_reconnect_calls += 1 }
    end
  end

  # Sleeper that records every requested sleep duration and signals between
  # ticks so tests can step through ticks deterministically.
  class TickSleeper
    attr_reader :requests

    def initialize
      @requests = Queue.new
      @release = Queue.new
      @stop = false
    end

    def call(duration)
      @requests << duration
      return if @stop
      @release.pop
    end

    def step
      @release << :go
    end

    def stop
      @stop = true
      100.times { @release << :go }
    end
  end

  def test_no_force_reconnect_when_last_event_recent
    now = Time.utc(2026, 5, 17, 0, 0, 0)
    stream = FakeStreamManager.new(last_event_at: now - 5, running: true)
    sleeper = TickSleeper.new

    watchdog = Tempest::Jetstream::Watchdog.new(
      stream_manager: stream,
      threshold_seconds: 90,
      interval_seconds: 30,
      clock: -> { now },
      sleeper: sleeper,
    )

    watchdog.start
    sleeper.requests.pop # wait for first sleep
    sleeper.step         # release tick 1
    sleeper.requests.pop # wait for sleep before tick 2

    watchdog.stop

    assert_equal 0, stream.force_reconnect_calls
  end

  def test_force_reconnect_when_last_event_older_than_threshold
    now = Time.utc(2026, 5, 17, 0, 0, 0)
    stream = FakeStreamManager.new(last_event_at: now - 120, running: true)
    sleeper = TickSleeper.new

    watchdog = Tempest::Jetstream::Watchdog.new(
      stream_manager: stream,
      threshold_seconds: 90,
      interval_seconds: 30,
      clock: -> { now },
      sleeper: sleeper,
    )

    watchdog.start
    sleeper.requests.pop
    sleeper.step
    sleeper.requests.pop # tick 1 done; entered next sleep

    watchdog.stop

    assert_operator stream.force_reconnect_calls, :>=, 1
  end

  def test_no_force_reconnect_when_not_running
    now = Time.utc(2026, 5, 17, 0, 0, 0)
    stream = FakeStreamManager.new(last_event_at: now - 999, running: false)
    sleeper = TickSleeper.new

    watchdog = Tempest::Jetstream::Watchdog.new(
      stream_manager: stream,
      threshold_seconds: 90,
      interval_seconds: 30,
      clock: -> { now },
      sleeper: sleeper,
    )

    watchdog.start
    sleeper.requests.pop
    sleeper.step
    sleeper.requests.pop

    watchdog.stop

    assert_equal 0, stream.force_reconnect_calls
  end

  def test_no_force_reconnect_when_last_event_at_nil
    # Manager hasn't seen its first event yet (still connecting). Don't fight
    # — the threshold doesn't apply until at least one event has been seen.
    now = Time.utc(2026, 5, 17, 0, 0, 0)
    stream = FakeStreamManager.new(last_event_at: nil, running: true)
    sleeper = TickSleeper.new

    watchdog = Tempest::Jetstream::Watchdog.new(
      stream_manager: stream,
      threshold_seconds: 90,
      interval_seconds: 30,
      clock: -> { now },
      sleeper: sleeper,
    )

    watchdog.start
    sleeper.requests.pop
    sleeper.step
    sleeper.requests.pop

    watchdog.stop

    assert_equal 0, stream.force_reconnect_calls
  end

  def test_errors_inside_tick_do_not_kill_the_watchdog
    now = Time.utc(2026, 5, 17, 0, 0, 0)
    raising = Class.new do
      attr_reader :calls
      def initialize; @calls = 0; @mutex = Mutex.new; end
      def running?
        @mutex.synchronize { @calls += 1 }
        raise "boom from running?"
      end
      def last_event_at; nil; end
      def force_reconnect; end
    end.new

    sleeper = TickSleeper.new

    watchdog = Tempest::Jetstream::Watchdog.new(
      stream_manager: raising,
      threshold_seconds: 90,
      interval_seconds: 30,
      clock: -> { now },
      sleeper: sleeper,
    )

    watchdog.start

    sleeper.requests.pop
    sleeper.step
    sleeper.requests.pop # second sleep proves the loop survived the raise
    sleeper.step
    sleeper.requests.pop

    assert_operator raising.calls, :>=, 2

    watchdog.stop
  end

  def test_stop_is_idempotent
    now = Time.utc(2026, 5, 17, 0, 0, 0)
    stream = FakeStreamManager.new(last_event_at: now - 5)
    sleeper = TickSleeper.new

    watchdog = Tempest::Jetstream::Watchdog.new(
      stream_manager: stream,
      threshold_seconds: 90,
      interval_seconds: 30,
      clock: -> { now },
      sleeper: sleeper,
    )

    watchdog.start
    sleeper.requests.pop

    watchdog.stop
    watchdog.stop # second stop must not raise or hang
  end

  def test_stop_before_start_is_safe
    stream = FakeStreamManager.new(last_event_at: nil)
    watchdog = Tempest::Jetstream::Watchdog.new(stream_manager: stream)
    watchdog.stop # no thread running — must be a no-op
  end

  def test_accepts_logger_keyword
    channel = Tempest::DebugLog.null_channel
    stream = FakeStreamManager.new(last_event_at: nil)
    sleeper = TickSleeper.new

    watchdog = Tempest::Jetstream::Watchdog.new(
      stream_manager: stream,
      threshold_seconds: 90,
      interval_seconds: 30,
      clock: -> { Time.now },
      sleeper: sleeper,
      logger: channel,
    )

    watchdog.start
    sleeper.requests.pop
    watchdog.stop
  end

  def test_did_keyword_tags_log_events
    io = StringIO.new
    logger = Logger.new(io)
    logger.formatter = Tempest::DebugLog.formatter
    channel = Tempest::DebugLog::Channel.new(loggers: [logger])

    now = Time.utc(2026, 5, 18, 0, 0, 0)
    stream = FakeStreamManager.new(last_event_at: now - 700, running: true)
    sleeper = TickSleeper.new

    watchdog = Tempest::Jetstream::Watchdog.new(
      stream_manager: stream,
      threshold_seconds: 600,
      interval_seconds: 30,
      clock: -> { now },
      sleeper: sleeper,
      logger: channel,
      did: "did:plc:abc",
    )

    watchdog.start
    sleeper.requests.pop
    sleeper.step
    sleeper.requests.pop
    watchdog.stop

    assert_match(/event=stalled_detected[^\n]*did=did:plc:abc/, io.string)
  end
end
