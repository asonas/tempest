require_relative "../../tempest"
require_relative "client"

module Tempest
  module Jetstream
    # Runs a Jetstream::Client in a background thread so the REPL stays
    # responsive. The transport itself is fiber-based, but we keep that fiber
    # off the main thread to avoid interleaving with Reline's blocking read.
    class StreamManager
      def initialize(client:)
        @client = client
        @thread = nil
        @mutex = Mutex.new
      end

      def start(&on_event)
        @mutex.synchronize do
          return if @thread&.alive?

          @thread = Thread.new do
            Thread.current.report_on_exception = false
            begin
              @client.each_event(&on_event)
            rescue => e
              on_event.call(StreamError.new(e))
            end
          end
        end
      end

      def stop
        @mutex.synchronize do
          thread = @thread
          @thread = nil
          thread&.kill
          thread&.join
        end
      end

      def running?
        @mutex.synchronize { !!@thread&.alive? }
      end
    end

    StreamError = Struct.new(:cause)
  end
end
