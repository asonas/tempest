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

      def initialize(client:, backoff: DEFAULT_BACKOFF, sleeper: ->(s) { sleep(s) },
                     clock: -> { Time.now })
        @client = client
        @backoff = backoff
        @sleeper = sleeper
        @clock = clock
        @thread = nil
        @mutex = Mutex.new
        @stopping = false
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
      end

      def running?
        @mutex.synchronize { !!@thread&.alive? }
      end

      private

      def run(on_event)
        Thread.current.report_on_exception = false
        cursor = nil
        disconnected_at = nil
        attempt = 0

        until stopping?
          if attempt > 0 && disconnected_at && cursor
            offline = @clock.call - disconnected_at
            if offline > CURSOR_WINDOW_SECONDS
              on_event.call(StreamStatus.new(state: :gapped, since: disconnected_at))
              cursor = nil
            end
          end

          on_event.call(StreamStatus.new(state: :reconnecting)) if attempt > 0

          error = nil
          saw_event = false
          begin
            @client.each_event(cursor: cursor) do |event|
              cursor = event.time_us if event.respond_to?(:time_us) && event.time_us
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

          disconnected_at = @clock.call
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
