require_relative "test_helper"
require "tempest/jetstream/client"

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
end
