require_relative "../../tempest"
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
                     filter: nil)
        @client = client
        @backoff = backoff
        @sleeper = sleeper
        @clock = clock
        @cursor_store = cursor_store
        @cursor_save_interval = cursor_save_interval
        @filter = filter
        @thread = nil
        @mutex = Mutex.new
        @stopping = false
        @cursor_state = { live: nil, saved: nil }
      end

      def start(&on_event)
        @mutex.synchronize do
          return if @thread&.alive?
          @stopping = false
          @thread = Thread.new { run(on_event) }
        end
      end

      def stop
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

      private

      def run(on_event)
        Thread.current.report_on_exception = false
        cursor, startup_gap_since = load_initial_cursor
        if startup_gap_since
          on_event.call(StreamStatus.new(state: :gapped, since: startup_gap_since))
        end
        last_saved_cursor = cursor
        last_save_at = nil
        attempt = 0

        until stopping?
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
              on_event.call(
                StreamStatus.new(state: :gapped, since: Time.at(cursor / 1_000_000.0)),
              )
              cursor = nil
            end
          end

          on_event.call(StreamStatus.new(state: :reconnecting)) if attempt > 0

          error = nil
          saw_event = false
          begin
            @client.each_event(cursor: cursor) do |event|
              if event.respond_to?(:time_us) && event.time_us
                cursor = event.time_us
                @mutex.synchronize { @cursor_state[:live] = cursor }
                if @cursor_store && cursor != last_saved_cursor
                  now = @clock.call
                  if last_save_at.nil? || (now - last_save_at) >= @cursor_save_interval
                    @cursor_store.save(time_us: cursor, at: now)
                    last_saved_cursor = cursor
                    last_save_at = now
                    @mutex.synchronize { @cursor_state[:saved] = cursor }
                  end
                end
              end
              next if @filter && !@filter.call(event)

              if attempt > 0 && !saw_event
                on_event.call(StreamStatus.new(state: :live))
              end
              saw_event = true
              on_event.call(event)
            end
          rescue => e
            error = e
            on_event.call(StreamError.new(e))
          end

          break if stopping?

          # Force a final save on disconnect so we don't lose the tail between
          # the throttle interval and the connection drop.
          if @cursor_store && cursor && cursor != last_saved_cursor
            now = @clock.call
            @cursor_store.save(time_us: cursor, at: now)
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
        end
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
