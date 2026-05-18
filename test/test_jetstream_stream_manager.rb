require_relative "test_helper"
require "logger"
require "tempest/debug_log"
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
  # In-memory CursorStore double. Behaves like the real one but skips disk.
  class FakeCursorStore
    attr_reader :saves

    def initialize(initial: nil)
      @initial = initial
      @saves = []
      @mutex = Mutex.new
    end

    def load
      @initial
    end

    def save(time_us:, at: Time.now)
      @mutex.synchronize { @saves << { time_us: time_us, saved_at: at } }
    end

    def last_saved_time_us
      @mutex.synchronize { @saves.last&.dig(:time_us) }
    end
  end

  def test_stop_flushes_latest_cursor_even_if_killed_mid_stream
    # The worst case: stop() arrives while the manager is blocked inside
    # each_event (the WebSocket is parked on read). thread.kill drops the
    # connection, so the disconnect path may not run. We still want the most
    # recent cursor flushed to disk — including events the throttle had
    # suppressed.
    store = FakeCursorStore.new
    saw_two = Queue.new
    block_release = Queue.new

    blocking_client = Class.new do
      def initialize(sentinel:, block_release:)
        @sentinel = sentinel
        @block_release = block_release
      end

      def each_event(cursor: nil)
        # First event passes the throttle (last_save_at is nil → always saves).
        yield make("a", 100)
        # Second event arrives within the throttle interval → NOT saved.
        yield make("b", 200)
        @sentinel << :delivered
        @block_release.pop # block until stop kills us
      end

      private

      def make(rkey, time_us)
        Tempest::Jetstream::Event.new(
          kind: :commit, did: "did:plc:x", time_us: time_us,
          collection: "app.bsky.feed.post", operation: :create,
          rkey: rkey, cid: nil, text: "t", created_at: "2026-01-01T00:00:00Z",
        )
      end
    end.new(sentinel: saw_two, block_release: block_release)

    manager = Tempest::Jetstream::StreamManager.new(
      client: blocking_client,
      backoff: [0],
      sleeper: ->(_) {},
      cursor_store: store,
      cursor_save_interval: 3600, # huge: second event MUST be suppressed
    )

    manager.start { |_| }
    saw_two.pop
    manager.stop

    assert_equal 200, store.last_saved_time_us,
      "stop() must flush the latest cursor (200) even though the throttle skipped it"
  end

  def test_force_saves_cursor_on_disconnect_if_unsaved
    # Single event arrives within the throttle interval (no save), then the
    # connection closes. The disconnect path must flush the latest cursor.
    base = Time.utc(2026, 5, 15, 12, 0, 0)
    # First @clock.call is for the throttled save check; we make it skip by
    # returning a time within the interval. Second @clock.call is at
    # disconnect.
    clock_values = [base, base + 1, base + 2]
    clock = -> { clock_values.shift || base + 10 }

    store = FakeCursorStore.new
    client = ScriptedClient.new([
      [make_event(time_us: 77)],
      nil,
    ])
    manager = Tempest::Jetstream::StreamManager.new(
      client: client,
      backoff: [0],
      sleeper: ->(_) {},
      clock: clock,
      cursor_store: store,
      cursor_save_interval: 100, # large so the throttle never fires
    )

    manager.start { |_| }
    100.times do
      break if client.cursors_seen.length >= 2
      sleep 0.005
    end
    client.release_all
    manager.stop

    assert_equal [77], store.saves.map { |s| s[:time_us] }
  end

  def test_throttles_cursor_saves_during_live_tail
    # Three events arrive. Clock advances such that only the 1st and 3rd
    # cross the save interval; the middle event should be coalesced into the
    # third save.
    base = Time.utc(2026, 5, 15, 12, 0, 0)
    clock_values = [
      base,         # initial cursor load check (none)
      base,         # event 1 timestamp
      base + 1,     # event 2 timestamp: 1s after last save → skip
      base + 6,     # event 3 timestamp: 6s after last save → save
      base + 7,     # disconnect timestamp
      base + 8,     # subsequent loop iterations
    ]
    clock = -> { clock_values.shift || clock_values.last || base }

    store = FakeCursorStore.new
    client = ScriptedClient.new([
      [make_event(time_us: 10), make_event(time_us: 20), make_event(time_us: 30)],
      nil,
    ])
    manager = Tempest::Jetstream::StreamManager.new(
      client: client,
      backoff: [0],
      sleeper: ->(_) {},
      clock: clock,
      cursor_store: store,
      cursor_save_interval: 5,
    )

    manager.start { |_| }
    100.times do
      break if client.cursors_seen.length >= 2
      sleep 0.005
    end
    client.release_all
    manager.stop

    saved_time_us = store.saves.map { |s| s[:time_us] }
    # First event always saves (interval elapsed from t=-inf), event 2 is
    # within interval so skipped, event 3 saves. Disconnect path may force a
    # final save which is fine — we only assert the throttling did its job.
    assert_includes saved_time_us, 10
    refute_includes saved_time_us, 20
    assert_includes saved_time_us, 30
  end

  def test_filter_predicate_suppresses_events_but_still_advances_cursor
    # Three events arrive; the filter accepts only the one with did:plc:keep.
    # The cursor (last_time_us) must still advance past the rejected events so
    # a reconnect uses the most recent time_us, not the most recent ACCEPTED
    # time_us — otherwise Jetstream would replay rejected events too.
    base = Time.utc(2026, 5, 15, 12, 0, 0)
    e1 = Tempest::Jetstream::Event.new(
      kind: :commit, did: "did:plc:skip1", time_us: 100,
      collection: "app.bsky.feed.post", operation: :create,
      rkey: "r1", cid: nil, text: "junk", created_at: "2026-01-01T00:00:00Z",
    )
    e2 = Tempest::Jetstream::Event.new(
      kind: :commit, did: "did:plc:keep", time_us: 200,
      collection: "app.bsky.feed.post", operation: :create,
      rkey: "r2", cid: nil, text: "hello", created_at: "2026-01-01T00:00:00Z",
    )
    e3 = Tempest::Jetstream::Event.new(
      kind: :commit, did: "did:plc:skip2", time_us: 300,
      collection: "app.bsky.feed.post", operation: :create,
      rkey: "r3", cid: nil, text: "junk2", created_at: "2026-01-01T00:00:00Z",
    )

    client = ScriptedClient.new([
      [e1, e2, e3],
      nil,
    ])
    manager = Tempest::Jetstream::StreamManager.new(
      client: client,
      backoff: [0],
      sleeper: ->(_) {},
      # Anchor the clock near the tiny scripted time_us values so the cursor
      # never looks stale (cursor age = clock - cursor_time / 1e6).
      clock: -> { Time.at(0) },
      filter: ->(event) { event.did == "did:plc:keep" },
    )

    delivered = Queue.new
    manager.start do |event|
      delivered << event if event.is_a?(Tempest::Jetstream::Event)
    end

    100.times do
      break if client.cursors_seen.length >= 2
      sleep 0.005
    end
    client.release_all
    manager.stop

    delivered_events = []
    delivered_events << delivered.pop until delivered.empty?
    assert_equal ["did:plc:keep"], delivered_events.map(&:did)
    # Reconnect must have used the highest time_us, including from skipped events
    assert_equal [nil, 300], client.cursors_seen
  end

  def test_uses_stored_cursor_when_fresh
    base_time = Time.utc(2026, 5, 15, 12, 0, 0)
    store = FakeCursorStore.new(initial: {
      time_us: 4242,
      saved_at: base_time - (1 * 60 * 60), # 1h ago, well within window
    })
    client = ScriptedClient.new([nil]) # first call blocks; we just want the cursor passed
    manager = Tempest::Jetstream::StreamManager.new(
      client: client,
      backoff: [0],
      sleeper: ->(_) {},
      clock: -> { base_time },
      cursor_store: store,
    )

    manager.start { |_| }
    100.times do
      break if client.cursors_seen.length >= 1
      sleep 0.005
    end
    client.release_all
    manager.stop

    assert_equal [4242], client.cursors_seen
  end

  def test_ignores_stored_cursor_when_stale
    base_time = Time.utc(2026, 5, 15, 12, 0, 0)
    store = FakeCursorStore.new(initial: {
      time_us: 9999,
      saved_at: base_time - (13 * 60 * 60), # 13h ago, beyond 12h window
    })
    client = ScriptedClient.new([nil])
    manager = Tempest::Jetstream::StreamManager.new(
      client: client,
      backoff: [0],
      sleeper: ->(_) {},
      clock: -> { base_time },
      cursor_store: store,
    )

    manager.start { |_| }
    100.times do
      break if client.cursors_seen.length >= 1
      sleep 0.005
    end
    client.release_all
    manager.stop

    assert_equal [nil], client.cursors_seen
  end

  def test_long_offline_emits_gapped_and_drops_cursor
    # The most recent event we received was emitted 13h ago. On reconnect the
    # cursor's age (clock - cursor_time) exceeds the 12h replay window, so we
    # must emit :gapped (with `since` derived from the cursor itself) and drop
    # the cursor before the next subscription. This models the "Mac slept for
    # 13h with tempest running" case where `disconnected_at` is unreliable
    # (the background thread was suspended too).
    base_time = Time.utc(2026, 5, 15, 12, 0, 0)
    cursor_time = base_time - (13 * 60 * 60)
    cursor_us = (cursor_time.to_f * 1_000_000).to_i

    clock = -> { base_time }

    client = ScriptedClient.new([
      [make_event(time_us: cursor_us)],
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
    assert_in_delta cursor_time.to_f, gapped.since.to_f, 0.001
  end

  def test_short_offline_preserves_cursor_and_does_not_emit_gapped
    # The cursor was last advanced 1h ago — well inside the replay window.
    # The reconnect must reuse the cursor (no :gapped, no dropped cursor).
    base_time = Time.utc(2026, 5, 15, 12, 0, 0)
    cursor_time = base_time - (1 * 60 * 60)
    cursor_us = (cursor_time.to_f * 1_000_000).to_i

    clock = -> { base_time }

    client = ScriptedClient.new([
      [make_event(time_us: cursor_us)],
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

    assert_equal [nil, cursor_us], client.cursors_seen
    refute drain(statuses).any? { |s| s.state == :gapped },
      "did not expect :gapped for a 1h offline window"
  end

  def test_stale_persisted_cursor_on_startup_emits_gapped_before_subscribing
    # A cursor persisted 13h ago is stale. On startup we must:
    #   1. emit :gapped (so the Runner backfills via getTimeline), and
    #   2. subscribe without a cursor (live tail only).
    base_time = Time.utc(2026, 5, 15, 12, 0, 0)
    stale_saved_at = base_time - (13 * 60 * 60)
    store = FakeCursorStore.new(initial: {
      time_us: 9999,
      saved_at: stale_saved_at,
    })

    client = ScriptedClient.new([nil])
    manager = Tempest::Jetstream::StreamManager.new(
      client: client,
      backoff: [0],
      sleeper: ->(_) {},
      clock: -> { base_time },
      cursor_store: store,
    )

    statuses = Queue.new
    manager.start do |event|
      statuses << event if event.is_a?(Tempest::Jetstream::StreamStatus)
    end

    100.times do
      break if client.cursors_seen.length >= 1
      sleep 0.005
    end
    client.release_all
    manager.stop

    assert_equal [nil], client.cursors_seen
    gapped = drain(statuses).find { |s| s.state == :gapped }
    refute_nil gapped, "expected :gapped to be emitted on startup with a stale persisted cursor"
    assert_in_delta stale_saved_at.to_f, gapped.since.to_f, 0.001
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
      # Anchor the clock near the scripted time_us values so the cursor never
      # looks stale on reconnect (cursor age = clock - cursor_time / 1e6).
      clock: -> { Time.at(0) },
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
      # Anchor the clock near the scripted time_us so the cursor stays fresh.
      clock: -> { Time.at(0) },
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

  # On force_reconnect (and on any reconnect that preserves the cursor),
  # Jetstream replays events from the cursor inclusive — the very event whose
  # time_us became the cursor is re-yielded by each_event. We must drop those
  # replays at the manager level so on_event doesn't see the same post twice.
  def test_does_not_re_emit_events_at_or_below_previous_cursor_after_reconnect
    event_200 = make_event(time_us: 200, text: "first")
    event_300 = make_event(time_us: 300, text: "second")

    client = ScriptedClient.new([
      [event_200],                      # initial connection: yield then close
      [event_200, event_300],           # reconnect replays event_200, then a new one
      nil,
    ])
    manager = Tempest::Jetstream::StreamManager.new(
      client: client,
      backoff: [0],
      sleeper: ->(_) {},
      clock: -> { Time.at(0) },
    )

    delivered = Queue.new
    manager.start do |e|
      delivered << e if e.is_a?(Tempest::Jetstream::Event)
    end

    100.times do
      break if client.cursors_seen.length >= 3
      sleep 0.005
    end
    client.release_all
    manager.stop

    texts = []
    texts << delivered.pop.text until delivered.empty?
    assert_equal ["first", "second"], texts,
      "the replayed event_200 must not be delivered a second time"
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
      # Anchor the clock near the scripted time_us so the cursor stays fresh.
      clock: -> { Time.at(0) },
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

  def test_accepts_logger_keyword_and_defaults_to_null_logger
    client = FakeClient.new(block_on_iteration: true)
    manager = Tempest::Jetstream::StreamManager.new(client: client)
    manager.start { |_| }
    manager.stop

    # Should also accept an explicit channel without raising.
    channel = Tempest::DebugLog.null_channel
    manager2 = Tempest::Jetstream::StreamManager.new(client: client, logger: channel)
    manager2.start { |_| }
    manager2.stop
  end

  def test_did_keyword_tags_log_events
    io = StringIO.new
    logger = Logger.new(io)
    logger.formatter = Tempest::DebugLog.formatter
    channel = Tempest::DebugLog::Channel.new(loggers: [logger])

    client = FakeClient.new(block_on_iteration: true)
    manager = Tempest::Jetstream::StreamManager.new(
      client: client, logger: channel, did: "did:plc:abc",
    )
    manager.start { |_| }
    manager.stop

    assert_match(/event=stopping[^\n]*did=did:plc:abc/, io.string)
  end

  def test_last_event_at_is_nil_before_any_event
    client = FakeClient.new(block_on_iteration: true)
    manager = Tempest::Jetstream::StreamManager.new(client: client)
    assert_nil manager.last_event_at
    manager.start { |_| }
    manager.stop
  end

  def test_last_event_at_updated_to_clock_time_when_event_yielded
    now = Time.utc(2026, 5, 17, 0, 0, 0)
    seen = Queue.new
    client = ScriptedClient.new([
      [make_event(time_us: 1)],
      nil,
    ])
    manager = Tempest::Jetstream::StreamManager.new(
      client: client,
      backoff: [0],
      sleeper: ->(_) {},
      clock: -> { now },
    )

    manager.start { |e| seen << e if e.is_a?(Tempest::Jetstream::Event) }
    seen.pop # wait for first event

    assert_equal now, manager.last_event_at

    client.release_all
    manager.stop
  end

  def test_last_event_at_updates_for_filtered_events_too
    # Filter suppresses display but the watchdog should still consider the
    # stream "alive" — server data is flowing.
    now = Time.utc(2026, 5, 17, 0, 0, 0)
    e_skip = Tempest::Jetstream::Event.new(
      kind: :commit, did: "did:plc:skip", time_us: 100,
      collection: "app.bsky.feed.post", operation: :create,
      rkey: "r1", cid: nil, text: "junk", created_at: "2026-01-01T00:00:00Z",
    )
    client = ScriptedClient.new([
      [e_skip],
      nil,
    ])
    manager = Tempest::Jetstream::StreamManager.new(
      client: client,
      backoff: [0],
      sleeper: ->(_) {},
      clock: -> { now },
      filter: ->(_e) { false },
    )

    manager.start { |_| }
    100.times do
      break if manager.last_event_at
      sleep 0.005
    end

    assert_equal now, manager.last_event_at

    client.release_all
    manager.stop
  end

  def test_force_reconnect_breaks_blocked_each_event_and_triggers_reconnect
    # Client first call blocks indefinitely simulating a stalled socket; we
    # then call force_reconnect and expect a SECOND each_event call to happen.
    gate1 = Queue.new
    gate2 = Queue.new
    in_first = Queue.new

    stalled_client = Class.new do
      attr_reader :calls

      def initialize(in_first:, gate1:, gate2:)
        @in_first = in_first
        @gate1 = gate1
        @gate2 = gate2
        @calls = 0
        @mutex = Mutex.new
      end

      def each_event(cursor: nil)
        call = @mutex.synchronize { @calls += 1 }
        if call == 1
          @in_first << :ready
          @gate1.pop # simulate stalled recv
        else
          @gate2.pop
        end
      end

      def release
        100.times { @gate1 << :go }
        100.times { @gate2 << :go }
      end
    end.new(in_first: in_first, gate1: gate1, gate2: gate2)

    manager = Tempest::Jetstream::StreamManager.new(
      client: stalled_client,
      backoff: [0],
      sleeper: ->(_) {},
    )

    manager.start { |_| }
    in_first.pop # wait until we're parked inside each_event #1

    manager.force_reconnect

    # Wait for the second each_event call to start.
    50.times do
      break if stalled_client.calls >= 2
      sleep 0.01
    end

    assert_equal 2, stalled_client.calls,
      "force_reconnect should unblock first call and trigger a second each_event"

    stalled_client.release
    manager.stop
  end

  def test_force_reconnect_is_safe_when_not_running
    client = FakeClient.new
    manager = Tempest::Jetstream::StreamManager.new(client: client)

    # Must not raise even if there is no worker thread.
    manager.force_reconnect
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

  # Regression: when the watchdog fires force_reconnect during the worker's
  # backoff sleep (Stalled raised outside the `rescue Stalled` block that wraps
  # each_event), the worker thread used to escape uncaught and die silently.
  # The reconnect loop must absorb that Stalled and keep going.
  def test_stalled_raised_during_backoff_sleep_does_not_kill_worker
    in_first = Queue.new
    gate_first = Queue.new
    gate_second = Queue.new
    in_sleep = Queue.new

    client = Class.new do
      attr_reader :calls

      def initialize(in_first:, gate_first:, gate_second:)
        @in_first = in_first
        @gate_first = gate_first
        @gate_second = gate_second
        @calls = 0
        @mutex = Mutex.new
      end

      def each_event(cursor: nil)
        call = @mutex.synchronize { @calls += 1 }
        if call == 1
          @in_first << :ready
          @gate_first.pop
          # Return normally to send the worker into backoff sleep.
        else
          @gate_second.pop
        end
      end

      def release
        100.times { @gate_first << :go }
        100.times { @gate_second << :go }
      end
    end.new(in_first: in_first, gate_first: gate_first, gate_second: gate_second)

    # Custom sleeper that signals when the worker enters backoff sleep, then
    # blocks on a queue so the test can park the worker exactly there.
    sleeper = Class.new do
      def initialize(in_sleep:)
        @in_sleep = in_sleep
        @gate = Queue.new
      end

      def call(_duration)
        @in_sleep << :sleeping
        @gate.pop
      end

      def release
        100.times { @gate << :go }
      end
    end.new(in_sleep: in_sleep)

    manager = Tempest::Jetstream::StreamManager.new(
      client: client,
      backoff: [0],
      sleeper: sleeper,
    )

    manager.start { |_| }
    in_first.pop # parked inside each_event #1
    gate_first << :go # let each_event return normally → worker enters backoff sleep
    in_sleep.pop # worker is now blocked in @sleeper.call

    # Fire force_reconnect; this raises Stalled into the worker thread while
    # it is in the backoff sleep — which is OUTSIDE the inner `rescue Stalled`
    # around each_event. The outer loop must catch it and continue.
    manager.force_reconnect

    sleeper.release

    # Wait for the worker to enter each_event the second time. If the Stalled
    # escaped run/, the thread is dead and we'll never see calls==2.
    100.times do
      break if client.calls >= 2
      sleep 0.01
    end

    assert_equal 2, client.calls,
      "Stalled raised during backoff sleep must not kill the worker"
    assert manager.running?, "worker must still be alive after Stalled in sleep"

    client.release
    manager.stop
  end

  # Regression: after force_reconnect, the watchdog used to immediately re-fire
  # (because @last_event_at was unchanged), raising a second Stalled at a
  # vulnerable spot. Reset last_event_at to "now" inside force_reconnect so a
  # follow-up tick sees the connection as fresh and the worker gets time to
  # reconnect.
  def test_force_reconnect_resets_last_event_at_to_prevent_double_fire
    event = Tempest::Jetstream::Event.new(
      kind: :commit, did: "did:plc:x", time_us: 1,
      collection: "app.bsky.feed.post", operation: :create,
      rkey: "r", cid: nil, text: "hi", created_at: "2026-01-01T00:00:00Z",
    )
    client = FakeClient.new(events: [event], block_on_iteration: true)

    now = Time.utc(2026, 5, 17, 0, 0, 0)
    event_time = Time.utc(2026, 5, 16, 23, 0, 0) # 1h ago — would trip a 600s watchdog
    clock_times = [event_time, now]
    clock = -> { clock_times.length > 1 ? clock_times.shift : clock_times.first }

    manager = Tempest::Jetstream::StreamManager.new(
      client: client,
      backoff: [0],
      clock: clock,
    )
    manager.start { |_| }

    # Wait until the worker has yielded one event and recorded last_event_at.
    100.times do
      break if manager.last_event_at
      sleep 0.005
    end
    assert_equal event_time, manager.last_event_at

    manager.force_reconnect

    # Inspect immediately: last_event_at should be advanced to `now` so the
    # next watchdog tick won't see it as stale and re-fire.
    assert_equal now, manager.last_event_at,
      "force_reconnect must reset last_event_at to the current clock time"

    manager.stop
  end
end
