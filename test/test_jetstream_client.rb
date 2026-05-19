require_relative "test_helper"
require "tempest/jetstream/client"
require "async"
require "async/websocket/client"
require "console"

class TestJetstreamClient < Minitest::Test
  class StubTransport
    attr_reader :opened_url

    def initialize(messages)
      @messages = messages
    end

    def each_message(url)
      @opened_url = url
      @messages.each { |msg| yield msg }
    end
  end

  def test_subscribe_url_without_filters
    client = Tempest::Jetstream::Client.new(
      url: "wss://jetstream2.us-east.bsky.network/subscribe",
    )
    assert_equal "wss://jetstream2.us-east.bsky.network/subscribe", client.subscribe_url
  end

  def test_subscribe_url_includes_wanted_collections_and_dids
    client = Tempest::Jetstream::Client.new(
      url: "wss://jetstream2.us-east.bsky.network/subscribe",
      wanted_collections: ["app.bsky.feed.post"],
      wanted_dids: ["did:plc:a", "did:plc:b"],
    )

    url = client.subscribe_url
    assert_includes url, "wantedCollections=app.bsky.feed.post"
    assert_includes url, "wantedDids=did%3Aplc%3Aa"
    assert_includes url, "wantedDids=did%3Aplc%3Ab"
  end

  def test_subscribe_url_includes_cursor_when_given
    client = Tempest::Jetstream::Client.new(
      url: "wss://jetstream2.us-east.bsky.network/subscribe",
      wanted_collections: ["app.bsky.feed.post"],
    )

    url = client.subscribe_url(cursor: 1_725_519_626_134_432)
    assert_includes url, "cursor=1725519626134432"
  end

  def test_subscribe_url_omits_cursor_when_nil
    client = Tempest::Jetstream::Client.new(
      url: "wss://jetstream2.us-east.bsky.network/subscribe",
      wanted_collections: ["app.bsky.feed.post"],
    )

    url = client.subscribe_url(cursor: nil)
    refute_includes url, "cursor"
  end

  def test_each_event_yields_decoded_events
    payload = JSON.generate(
      did: "did:plc:x",
      time_us: 1,
      kind: "commit",
      commit: {
        operation: "create",
        collection: "app.bsky.feed.post",
        rkey: "r1",
        record: { "$type" => "app.bsky.feed.post", text: "hello", createdAt: "2026-01-01T00:00:00Z" },
      },
    )
    other = JSON.generate(kind: "account", did: "did:plc:y", time_us: 2)

    transport = StubTransport.new([payload, other, "not json"])
    client = Tempest::Jetstream::Client.new(
      url: "wss://example.test/subscribe",
      wanted_collections: ["app.bsky.feed.post"],
      transport: transport,
    )

    events = []
    client.each_event { |event| events << event }

    assert_equal "wss://example.test/subscribe?wantedCollections=app.bsky.feed.post", transport.opened_url
    assert_equal 1, events.length
    assert_equal "hello", events.first.text
  end

  def test_each_event_passes_cursor_through_to_transport
    transport = StubTransport.new([])
    client = Tempest::Jetstream::Client.new(
      url: "wss://example.test/subscribe",
      wanted_collections: ["app.bsky.feed.post"],
      transport: transport,
    )

    client.each_event(cursor: 1_725_519_626_134_432) { |_| }

    assert_includes transport.opened_url, "cursor=1725519626134432"
  end

  # When DNS resolution fails (e.g. laptop wakes with no Wi-Fi), the async
  # gem's default behavior is to log "Task may have ended with unhandled
  # exception." via Console.logger.warn before the exception propagates out
  # of `.wait`. That warning ends up in the TUI as a multi-line stack trace.
  # The StreamManager already catches the exception and reconnects, so this
  # diagnostic noise is purely harmful. The transport must suppress it by
  # passing `finished: false` to the outer Async task so the underlying
  # promise marks itself as having warnings suppressed.
  class WarnCapturingLogger
    attr_reader :warn_calls

    def initialize
      @warn_calls = []
    end

    def warn(*args, **kwargs, &block)
      @warn_calls << [args, kwargs]
    end

    def method_missing(*_args, **_kwargs); end
    def respond_to_missing?(*); true; end
  end

  def test_each_message_suppresses_async_task_unhandled_exception_warning
    transport = Tempest::Jetstream::AsyncWebSocketTransport.new

    original_logger = Console.logger
    capturing = WarnCapturingLogger.new
    Console.logger = capturing

    original_connect = Async::WebSocket::Client.method(:connect)
    Async::WebSocket::Client.define_singleton_method(:connect) do |_endpoint, **_kw, &_block|
      raise Socket::ResolutionError, "getaddrinfo: nodename nor servname provided (test stub)"
    end

    begin
      assert_raises(Socket::ResolutionError) do
        transport.each_message("wss://stub.invalid/subscribe") { |_| }
      end
    ensure
      Async::WebSocket::Client.singleton_class.send(:define_method, :connect, original_connect)
      Console.logger = original_logger
    end

    unhandled = capturing.warn_calls.flat_map { |args, _| args }.any? do |arg|
      arg.is_a?(String) && arg.include?("unhandled exception")
    end
    refute unhandled, "Console.logger.warn received an async 'unhandled exception' notice; expected finished: false to suppress it"
  end
end
