require_relative "test_helper"
require "tempest/jetstream/stream_manager"
require "tempest/jetstream/client"

class TestJetstreamStreamManager < Minitest::Test
  class FakeClient
    attr_reader :started

    def initialize(events: [], block_on_iteration: false)
      @events = events
      @block_on_iteration = block_on_iteration
      @started = 0
    end

    def each_event(cursor: nil)
      @started += 1
      @events.each { |e| yield e }
      sleep 0.5 if @block_on_iteration
    end
  end

  # Records the cursor passed on each call and yields the next scripted batch
  # of events. After all scripted batches are exhausted, the call blocks until
  # `stop` is requested so the test can join cleanly.
  class ScriptedClient
    attr_reader :cursors_seen

    def initialize(batches)
      @batches = batches
      @cursors_seen = []
      @gate = Queue.new
      @mutex = Mutex.new
    end

    def each_event(cursor: nil)
      index = @mutex.synchronize do
        @cursors_seen << cursor
        @cursors_seen.length - 1
      end

      batch = @batches[index]
      if batch.nil?
        @gate.pop # block until release
        return
      end

      batch.each { |e| yield e }
      # returns normally → triggers reconnect
    end

    def release_all
      100.times { @gate << :go }
    end
  end

  def test_start_invokes_callback_for_each_event
    event = Tempest::Jetstream::Event.new(
      kind: :commit, did: "did:plc:x", time_us: 1,
      collection: "app.bsky.feed.post", operation: :create,
      rkey: "r", cid: nil, text: "hello", created_at: "2026-01-01T00:00:00Z",
    )
    client = FakeClient.new(events: [event])
    received = Queue.new
    manager = Tempest::Jetstream::StreamManager.new(client: client)

    manager.start { |e| received << e }

    captured = received.pop
    assert_equal "hello", captured.text
    manager.stop
  end

  def test_running_reflects_state
    client = FakeClient.new(block_on_iteration: true)
    manager = Tempest::Jetstream::StreamManager.new(client: client)
    refute manager.running?

    manager.start { |_| }
    # wait until worker boots
    50.times do
      break if manager.running?
      sleep 0.005
    end
    assert manager.running?

    manager.stop
    refute manager.running?
  end

  def make_event(time_us:, text: "hi")
    Tempest::Jetstream::Event.new(
      kind: :commit, did: "did:plc:x", time_us: time_us,
      collection: "app.bsky.feed.post", operation: :create,
      rkey: "r", cid: nil, text: text, created_at: "2026-01-01T00:00:00Z",
    )
  end

  # Like ScriptedClient but raises after yielding its first batch — models the
  # transport blowing up (TLS reset, server kick) rather than closing cleanly.
  class RaisingScriptedClient
    attr_reader :cursors_seen

    def initialize(first_batch:, exception:)
      @first_batch = first_batch
      @exception = exception
      @cursors_seen = []
      @gate = Queue.new
      @mutex = Mutex.new
    end

    def each_event(cursor: nil)
      call = @mutex.synchronize do
        @cursors_seen << cursor
        @cursors_seen.length
      end

      if call == 1
        @first_batch.each { |e| yield e }
        raise @exception
      else
        @gate.pop
      end
    end

    def release_all
      100.times { @gate << :go }
    end
  end

  # When the offline window (wall clock between the disconnect and the next
  # reconnect attempt) exceeds Jetstream's conservative replay TTL, the cursor
  # we hold is likely stale. The manager should emit :gapped and drop the
  # cursor so the next subscription is a fresh live-tail; the Runner is then
  # responsible for falling back to getTimeline for display backfill.
  def test_long_offline_emits_gapped_and_drops_cursor
    base_time = Time.utc(2026, 5, 15, 12, 0, 0)
    times = [
      base_time,                           # disconnect captured here
      base_time + (13 * 60 * 60),          # 13h later: beyond 12h window
    ]
    clock = ->() { times.shift || base_time + (24 * 60 * 60) }

    client = ScriptedClient.new([
      [make_event(time_us: 999)],
      nil,
    ])
    manager = Tempest::Jetstream::StreamManager.new(
      client: client,
      backoff: [0],
      sleeper: ->(_) {},
      clock: clock,
    )

    statuses = Queue.new
    manager.start do |event|
      statuses << event if event.is_a?(Tempest::Jetstream::StreamStatus)
    end

    100.times do
      break if client.cursors_seen.length >= 2
      sleep 0.005
    end

    client.release_all
    manager.stop

    assert_equal [nil, nil], client.cursors_seen
    gapped = drain(statuses).find { |s| s.state == :gapped }
    refute_nil gapped, "expected a :gapped status when offline exceeded window"
    assert_equal base_time, gapped.since
  end

  def drain(queue)
    out = []
    out << queue.pop until queue.empty?
    out
  end

  def test_stop_aborts_the_reconnect_loop_during_backoff
    # The sleeper blocks on a queue until the test pushes; we want stop() to
    # be called while the manager is inside that sleep, and then verify the
    # next each_event call is NOT made.
    sleep_gate = Queue.new
    in_sleep = Queue.new
    client = ScriptedClient.new([[], nil])
    manager = Tempest::Jetstream::StreamManager.new(
      client: client,
      backoff: [1],
      sleeper: ->(_) {
        in_sleep << :reached
        sleep_gate.pop
      },
    )

    manager.start { |_| }
    in_sleep.pop # wait until we're sleeping between reconnects

    initial_calls = client.cursors_seen.length
    manager.stop

    # If stop didn't break the loop, more calls would happen. Give it a moment.
    sleep 0.05
    assert_equal initial_calls, client.cursors_seen.length

    refute manager.running?
  end

  def test_backoff_grows_and_caps_at_the_last_step
    client = ScriptedClient.new([[], [], [], [], [], [], [], nil])
    sleeps = Queue.new
    manager = Tempest::Jetstream::StreamManager.new(
      client: client,
      backoff: [1, 2, 5, 10, 30],
      sleeper: ->(s) { sleeps << s },
    )

    manager.start { |_| }
    100.times do
      break if client.cursors_seen.length >= 7
      sleep 0.005
    end
    client.release_all
    manager.stop

    captured = []
    captured << sleeps.pop until sleeps.empty?
    assert_equal [1, 2, 5, 10, 30, 30], captured.first(6)
  end

  def test_emits_reconnecting_then_live_around_reconnect
    client = ScriptedClient.new([
      [make_event(time_us: 100)], # first connection, then clean close
      [make_event(time_us: 200)], # second connection yields an event then closes
      nil,                         # third call blocks
    ])
    manager = Tempest::Jetstream::StreamManager.new(
      client: client,
      backoff: [0],
      sleeper: ->(_) {},
    )

    statuses = Queue.new
    manager.start do |event|
      statuses << event if event.is_a?(Tempest::Jetstream::StreamStatus)
    end

    # First connection closes
    disconnect_1 = statuses.pop
    assert_equal :disconnected, disconnect_1.state

    # Before second connect: reconnecting
    reconnecting = statuses.pop
    assert_equal :reconnecting, reconnecting.state

    # First event of second connection triggers :live
    live = statuses.pop
    assert_equal :live, live.state

    client.release_all
    manager.stop
  end

  def test_emits_disconnected_status_after_clean_close
    client = ScriptedClient.new([
      [make_event(time_us: 100)],
      nil,
    ])
    manager = Tempest::Jetstream::StreamManager.new(
      client: client,
      backoff: [0],
      sleeper: ->(_) {},
    )

    statuses = Queue.new
    manager.start do |event|
      statuses << event if event.is_a?(Tempest::Jetstream::StreamStatus)
    end

    status = statuses.pop
    assert_equal :disconnected, status.state
    assert_equal :closed, status.reason

    client.release_all
    manager.stop
  end

  def test_emits_disconnected_status_with_error_reason_after_exception
    boom = StandardError.new("oops")
    client = RaisingScriptedClient.new(first_batch: [], exception: boom)
    manager = Tempest::Jetstream::StreamManager.new(
      client: client,
      backoff: [0],
      sleeper: ->(_) {},
    )

    statuses = Queue.new
    manager.start do |event|
      statuses << event if event.is_a?(Tempest::Jetstream::StreamStatus)
    end

    status = statuses.pop
    assert_equal :disconnected, status.state
    assert_equal :error, status.reason
    assert_equal boom, status.error

    client.release_all
    manager.stop
  end

  def test_reconnects_with_preserved_cursor_after_exception
    boom = StandardError.new("connection reset")
    client = RaisingScriptedClient.new(
      first_batch: [make_event(time_us: 555)],
      exception: boom,
    )
    manager = Tempest::Jetstream::StreamManager.new(
      client: client,
      backoff: [0],
      sleeper: ->(_) {},
    )

    errors = Queue.new
    manager.start do |event|
      errors << event if event.is_a?(Tempest::Jetstream::StreamError)
    end

    50.times do
      break if client.cursors_seen.length >= 2
      sleep 0.005
    end

    client.release_all
    manager.stop

    assert_equal [nil, 555], client.cursors_seen
    assert_equal boom, errors.pop.cause
  end

  def test_reconnects_with_last_time_us_as_cursor_after_clean_disconnect
    client = ScriptedClient.new([
      [make_event(time_us: 100), make_event(time_us: 200)],
      nil, # second connection blocks; we just want to inspect the cursor passed
    ])
    manager = Tempest::Jetstream::StreamManager.new(
      client: client,
      backoff: [0],
      sleeper: ->(_) {},
    )

    manager.start { |_| }

    50.times do
      break if client.cursors_seen.length >= 2
      sleep 0.005
    end

    client.release_all
    manager.stop

    assert_equal [nil, 200], client.cursors_seen
  end

  def test_double_start_is_idempotent
    client = FakeClient.new(block_on_iteration: true)
    manager = Tempest::Jetstream::StreamManager.new(client: client)

    manager.start { |_| }
    50.times { break if client.started == 1; sleep 0.005 }
    manager.start { |_| }
    50.times { sleep 0.005 } # give second start a chance to spawn a worker if buggy

    assert_equal 1, client.started
    manager.stop
  end
end
