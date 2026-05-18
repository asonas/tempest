require_relative "../../tempest"
require_relative "../debug_log"
require_relative "client"

module Tempest
  module Jetstream
    # Runs a Jetstream::Client in a background thread so the REPL stays
    # responsive. The transport itself is fiber-based, but we keep that fiber
    # off the main thread to avoid interleaving with Reline's blocking read.
    # Owns reconnect-with-cursor so a flaky socket or sleep/wake cycle doesn't
    # silently strand the live feed.
    class StreamManager
      DEFAULT_BACKOFF = [1, 2, 5, 10, 30].freeze
      # Conservative replay window: Jetstream's default event-ttl is 24h, but
      # Bluesky doesn't publicly commit to that for their hosted instances and
      # boundary cases (clock skew, tail trim races) bite around the limit. If
      # we've been offline longer than this, drop the cursor and let the Runner
      # backfill via getTimeline.
      CURSOR_WINDOW_SECONDS = 12 * 60 * 60
      # How often we persist the cursor during a stable live-tail. 5s caps the
      # worst-case event loss on crash to a few seconds of activity while
      # keeping disk writes negligible on a busy stream.
      DEFAULT_CURSOR_SAVE_INTERVAL = 5.0

      def initialize(client:, backoff: DEFAULT_BACKOFF, sleeper: ->(s) { sleep(s) },
                     clock: -> { Time.now }, cursor_store: nil,
                     cursor_save_interval: DEFAULT_CURSOR_SAVE_INTERVAL,
                     filter: nil, logger: nil, did: nil)
        @client = client
        @backoff = backoff
        @sleeper = sleeper
        @clock = clock
        @cursor_store = cursor_store
        @cursor_save_interval = cursor_save_interval
        @filter = filter
        base = logger || Tempest::DebugLog.null_channel
        @logger = did ? base.with(did: did) : base
        @thread = nil
        @mutex = Mutex.new
        @stopping = false
        @cursor_state = { live: nil, saved: nil }
        @last_event_at = nil
      end

      def start(&on_event)
        @mutex.synchronize do
          return if @thread&.alive?
          @stopping = false
          @thread = Thread.new { run(on_event) }
        end
      end

      def stop
        live = @mutex.synchronize { @cursor_state[:live] }
        @logger.info("stream", event: "stopping", final_cursor: live)
        @mutex.synchronize { @stopping = true }
        thread = @mutex.synchronize do
          t = @thread
          @thread = nil
          t
        end
        thread&.kill
        thread&.join
        flush_cursor!
      end

      def running?
        @mutex.synchronize { !!@thread&.alive? }
      end

      # Time of the last event yielded by the underlying client, regardless of
      # whether the filter accepted it. Watchdog reads this to detect a stalled
      # socket (kernel still thinks the TCP connection is alive but no bytes
      # are arriving).
      def last_event_at
        @mutex.synchronize { @last_event_at }
      end

      # Break a stalled each_event so the reconnect loop can run. Used by the
      # Watchdog when the kernel hasn't surfaced the disconnect (e.g., after
      # macOS sleep/wake). Safe to call from another thread or when no worker
      # is running.
      def force_reconnect
        thread = @mutex.synchronize { @thread }
        return unless thread&.alive?
        @logger.warn("stream", event: "force_reconnect_requested")
        # Pre-advance last_event_at so the watchdog's next tick sees a fresh
        # connection and doesn't re-fire while the worker is still recovering.
        # Without this, a second Stalled can land in the backoff sleep — which
        # is outside the inner `rescue Stalled` block — and would historically
        # take down the worker. The outer rescue in `run` now catches that
        # case too, but suppressing the duplicate force_reconnect is still the
        # right thing to do.
        @mutex.synchronize { @last_event_at = @clock.call }
        begin
          thread.raise(Stalled.new("forced reconnect"))
        rescue ThreadError
          # Thread already exited between alive? and raise — nothing to do.
        end
      end

      private

      def run(on_event)
        Thread.current.report_on_exception = false
        cursor, startup_gap_since = load_initial_cursor
        if startup_gap_since
          @logger.warn("stream", event: "startup_stale", stale_since: startup_gap_since)
          on_event.call(StreamStatus.new(state: :gapped, since: startup_gap_since))
        end
        last_saved_cursor = cursor
        last_save_at = nil
        attempt = 0

        @logger.info(
          "stream",
          event: "worker_start",
          cursor: cursor,
          cursor_age_seconds: cursor ? cursor_age_seconds(cursor) : nil,
        )

        until stopping?
          # The outer `rescue Stalled` below catches Stalled raised by
          # force_reconnect that lands OUTSIDE the inner each_event block —
          # e.g. during @sleeper.call(delay), the cursor age check, or the
          # disconnected/reconnecting status emission. Without this guard, a
          # second force_reconnect arriving during recovery used to escape
          # the inner rescue and silently kill the worker thread.
          begin
          # Detect a long offline gap from the cursor's age rather than from
          # wall-clock disconnect timestamps. When the host machine sleeps,
          # the background thread is suspended and we only learn about the
          # outage at wake time — `disconnected_at` would therefore reflect
          # the wake time, not the actual go-offline time, and the window
          # check would never fire. The cursor (a unix-microseconds event
          # timestamp from Jetstream) is unaffected by our suspension, so its
          # age is a reliable proxy for "how long since we last saw events".
          if attempt > 0 && cursor
            cursor_age = @clock.call.to_f - (cursor / 1_000_000.0)
            if cursor_age > CURSOR_WINDOW_SECONDS
              since = Time.at(cursor / 1_000_000.0)
              @logger.warn(
                "stream",
                event: "gapped",
                cursor_age_seconds: cursor_age.round(1),
                since: since,
              )
              on_event.call(StreamStatus.new(state: :gapped, since: since))
              cursor = nil
            end
          end

          if attempt > 0
            delay = @backoff[[attempt - 1, @backoff.length - 1].min]
            @logger.info(
              "stream",
              event: "reconnect_attempt",
              attempt: attempt,
              cursor: cursor,
              backoff_just_slept_seconds: delay,
            )
            on_event.call(StreamStatus.new(state: :reconnecting))
          end

          error = nil
          saw_event = false
          @logger.info("stream", event: "subscribe", cursor: cursor, attempt: attempt)
          begin
            @client.each_event(cursor: cursor) do |event|
              now = @clock.call
              @mutex.synchronize { @last_event_at = now }
              if event.respond_to?(:time_us) && event.time_us
                # Replay protection: when reconnecting with a preserved cursor,
                # Jetstream re-yields events at or below the cursor (the cursor
                # is inclusive). Drop them so downstream sees each event once.
                # last_event_at above is still updated, so the watchdog
                # correctly sees the connection as alive.
                next if cursor && event.time_us <= cursor
                cursor = event.time_us
                @mutex.synchronize { @cursor_state[:live] = cursor }
                if @cursor_store && cursor != last_saved_cursor
                  if last_save_at.nil? || (now - last_save_at) >= @cursor_save_interval
                    @cursor_store.save(time_us: cursor, at: now)
                    @logger.debug("stream", event: "cursor_save", cursor: cursor)
                    last_saved_cursor = cursor
                    last_save_at = now
                    @mutex.synchronize { @cursor_state[:saved] = cursor }
                  end
                end
              end
              next if @filter && !@filter.call(event)

              if attempt > 0 && !saw_event
                @logger.info("stream", event: "live_resumed", attempt: attempt, cursor: cursor)
                on_event.call(StreamStatus.new(state: :live))
              end
              saw_event = true
              on_event.call(event)
            end
          rescue Stalled => e
            error = e
            @logger.warn(
              "stream",
              event: "disconnected",
              reason: "stalled",
              cursor: cursor,
              error_class: e.class.name,
              error_message: e.message,
            )
            on_event.call(StreamError.new(e))
          rescue => e
            error = e
            @logger.warn(
              "stream",
              event: "disconnected",
              reason: "error",
              cursor: cursor,
              error_class: e.class.name,
              error_message: e.message,
            )
            on_event.call(StreamError.new(e))
          end

          break if stopping?

          # Force a final save on disconnect so we don't lose the tail between
          # the throttle interval and the connection drop.
          if @cursor_store && cursor && cursor != last_saved_cursor
            now = @clock.call
            @cursor_store.save(time_us: cursor, at: now)
            @logger.debug("stream", event: "cursor_save_on_disconnect", cursor: cursor)
            last_saved_cursor = cursor
            last_save_at = now
            @mutex.synchronize { @cursor_state[:saved] = cursor }
          end

          on_event.call(
            StreamStatus.new(
              state: :disconnected,
              reason: error ? :error : :closed,
              error: error,
            ),
          )

          delay = @backoff[[attempt, @backoff.length - 1].min]
          @sleeper.call(delay)
          attempt += 1
          rescue Stalled => e
            # Stalled landed outside the inner each_event rescue (typically
            # in @sleeper.call). Treat it as a transient blip and let the loop
            # try again instead of letting the worker thread die.
            @logger.warn(
              "stream",
              event: "stalled_outside_each_event",
              attempt: attempt,
              cursor: cursor,
              error_message: e.message,
            )
            attempt += 1
          end
        end

        @logger.info("stream", event: "worker_exit", final_cursor: cursor)
      end

      def cursor_age_seconds(cursor)
        return nil unless cursor
        (@clock.call - Time.at(cursor / 1_000_000.0)).round(1)
      rescue StandardError
        nil
      end

      def stopping?
        @mutex.synchronize { @stopping }
      end

      # Returns [cursor, gap_since]. `gap_since` is non-nil when a persisted
      # cursor existed but is too old to replay safely; the caller emits
      # :gapped (so the Runner backfills via getTimeline) and subscribes
      # without a cursor.
      def load_initial_cursor
        return [nil, nil] unless @cursor_store
        stored = @cursor_store.load
        return [nil, nil] unless stored && stored[:time_us] && stored[:saved_at]
        age = @clock.call - stored[:saved_at]
        return [nil, stored[:saved_at]] if age > CURSOR_WINDOW_SECONDS
        [stored[:time_us], nil]
      end

      # Called from `stop` after the worker thread has been killed. Ensures the
      # most recent in-memory cursor (which the throttle may have skipped over)
      # makes it to disk; otherwise a crash during a stable live-tail would
      # roll us back by `cursor_save_interval` worth of events on next launch.
      def flush_cursor!
        return unless @cursor_store
        live, saved = @mutex.synchronize { [@cursor_state[:live], @cursor_state[:saved]] }
        return unless live && live != saved
        @cursor_store.save(time_us: live, at: @clock.call)
        @mutex.synchronize { @cursor_state[:saved] = live }
      end
    end

    # Raised inside the worker thread by StreamManager#force_reconnect to
    # break a stalled each_event. The run loop catches it and treats it as a
    # disconnect, preserving the existing reconnect-with-cursor flow.
    class Stalled < StandardError; end

    StreamError = Struct.new(:cause)

    # Lifecycle status emitted alongside Event/StreamError on the same
    # on_event callback so the REPL can render "-- disconnected" /
    # "-- reconnecting" / "-- live" lines without coupling to the manager's
    # internals. `state` is one of :disconnected | :reconnecting | :live |
    # :gapped. `reason` is :closed | :error for :disconnected. `error` is the
    # underlying exception when reason == :error. `since` is the disconnect
    # time when state == :gapped.
    StreamStatus = Data.define(:state, :reason, :error, :since) do
      def initialize(state:, reason: nil, error: nil, since: nil)
        super
      end
    end
  end
end
