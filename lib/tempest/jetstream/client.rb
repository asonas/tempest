require "uri"

require_relative "../../tempest"
require_relative "decoder"

module Tempest
  module Jetstream
    DEFAULT_URL = "wss://jetstream2.us-east.bsky.network/subscribe".freeze

    class Client
      def initialize(url: DEFAULT_URL, wanted_collections: [], wanted_dids: [], decoder: Decoder, transport: nil)
        @url = url
        @wanted_collections = Array(wanted_collections)
        @wanted_dids = Array(wanted_dids)
        @decoder = decoder
        @transport = transport
      end

      def subscribe_url(cursor: nil)
        params = []
        @wanted_collections.each { |c| params << ["wantedCollections", c] }
        @wanted_dids.each { |d| params << ["wantedDids", d] }
        params << ["cursor", cursor.to_s] if cursor
        return @url if params.empty?

        uri = URI(@url)
        existing = uri.query ? URI.decode_www_form(uri.query) : []
        uri.query = URI.encode_www_form(existing + params)
        uri.to_s
      end

      def each_event(cursor: nil, &block)
        return enum_for(:each_event, cursor: cursor) unless block

        transport.each_message(subscribe_url(cursor: cursor)) do |raw|
          event = @decoder.decode(raw)
          yield event if event
        end
      end

      private

      def transport
        @transport ||= AsyncWebSocketTransport.new
      end
    end

    # Default WebSocket transport using async-websocket. Loaded lazily so unit
    # tests that inject a stub transport don't pull in the Async runtime.
    class AsyncWebSocketTransport
      def initialize
        require "async"
        require "async/http/endpoint"
        require "async/websocket/client"
      end

      def each_message(url)
        # `finished: false` makes Async::Task call `@promise.suppress_warnings!`
        # so that connect failures (DNS errors after offline wake-from-sleep,
        # TCP resets, TLS handshake errors) don't trigger Console.logger.warn
        # with "Task may have ended with unhandled exception." plus a full
        # backtrace. The exception still propagates via `.wait`; the
        # StreamManager's reconnect loop already handles it cleanly.
        Async(finished: false) do
          endpoint = Async::HTTP::Endpoint.parse(url)
          Async::WebSocket::Client.connect(endpoint) do |connection|
            while (message = connection.read)
              yield message.buffer
            end
          end
        end.wait
      end
    end
  end
end
