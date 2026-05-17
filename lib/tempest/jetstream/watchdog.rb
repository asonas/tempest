require_relative "../../tempest"
require_relative "../debug_log"

module Tempest
  module Jetstream
    # Detects stalled Jetstream connections and force-reconnects them.
    #
    # Background: after macOS sleep/wake the kernel may still consider the
    # WebSocket's TCP socket alive, so Jetstream::Client#each_event blocks in
    # `recv` indefinitely instead of raising. StreamManager's reconnect loop
    # therefore never runs. The watchdog periodically inspects
    # `stream_manager.last_event_at` and, if no event has arrived within
    # `threshold_seconds`, calls `force_reconnect` to break the stalled call.
    class Watchdog
      DEFAULT_THRESHOLD_SECONDS = 90
      DEFAULT_INTERVAL_SECONDS = 30

      def initialize(stream_manager:,
                     threshold_seconds: DEFAULT_THRESHOLD_SECONDS,
                     interval_seconds: DEFAULT_INTERVAL_SECONDS,
                     clock: -> { Time.now },
                     sleeper: ->(s) { sleep(s) },
                     logger: nil)
        @stream_manager = stream_manager
        @threshold_seconds = threshold_seconds
        @interval_seconds = interval_seconds
        @clock = clock
        @sleeper = sleeper
        @logger = logger || Tempest::DebugLog.build_null_logger
        @thread = nil
        @mutex = Mutex.new
        @stopping = false
      end

      def start
        @mutex.synchronize do
          return if @thread&.alive?
          @stopping = false
          @thread = Thread.new { run }
        end
      end

      def stop
        thread = @mutex.synchronize do
          @stopping = true
          t = @thread
          @thread = nil
          t
        end
        return unless thread
        thread.kill
        thread.join
      end

      private

      def run
        Thread.current.report_on_exception = false
        until stopping?
          @sleeper.call(@interval_seconds)
          break if stopping?
          tick
        end
      end

      def tick
        last = @stream_manager.last_event_at
        return unless @stream_manager.running?
        return if last.nil?

        elapsed = @clock.call - last
        return unless elapsed > @threshold_seconds

        @logger.warn("watchdog") do
          "stalled stream elapsed_seconds=#{elapsed.round(1)} threshold=#{@threshold_seconds} — forcing reconnect"
        end
        @stream_manager.force_reconnect
      rescue StandardError => e
        # Never let a bad clock, logger, or stream_manager bug kill the thread.
        # Best-effort log; if logger also raises, swallow.
        begin
          @logger.error("watchdog") { "tick error=#{e.class}: #{e.message}" }
        rescue StandardError
        end
      end

      def stopping?
        @mutex.synchronize { @stopping }
      end
    end
  end
end
