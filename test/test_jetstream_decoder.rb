require_relative "test_helper"
require "json"
require "tempest/jetstream/decoder"

class TestJetstreamDecoder < Minitest::Test
  def decode(payload)
    Tempest::Jetstream::Decoder.decode(payload)
  end

  def test_decode_returns_nil_for_invalid_json
    assert_nil decode("not json")
  end

  def test_decode_returns_nil_for_account_or_identity_kinds
    payload = { kind: "account", did: "did:plc:x", time_us: 1 }.to_json
    assert_nil decode(payload)
  end

  def test_decode_returns_event_for_post_create
    payload = {
      did: "did:plc:eygmaihciaxprqvxpfvl6flk",
      time_us: 1_725_911_162_329_308,
      kind: "commit",
      commit: {
        rev: "3l3qo2vutsw2b",
        operation: "create",
        collection: "app.bsky.feed.post",
        rkey: "3l3qo2vuowo2b",
        record: {
          "$type" => "app.bsky.feed.post",
          createdAt: "2024-09-09T19:46:02.102Z",
          langs: ["ja"],
          text: "おはよう",
        },
        cid: "bafyreidc6sydkkbchcyg62v77wbhzvb2mvytlmsychqgwf2xojjtirmzj4",
      },
    }.to_json

    event = decode(payload)

    refute_nil event
    assert_equal :commit, event.kind
    assert_equal "did:plc:eygmaihciaxprqvxpfvl6flk", event.did
    assert_equal 1_725_911_162_329_308, event.time_us
    assert_equal "app.bsky.feed.post", event.collection
    assert_equal :create, event.operation
    assert_equal "3l3qo2vuowo2b", event.rkey
    assert_equal "おはよう", event.text
    assert_equal "2024-09-09T19:46:02.102Z", event.created_at
  end

  def test_decode_returns_event_for_post_delete_without_record
    payload = {
      did: "did:plc:x",
      time_us: 1,
      kind: "commit",
      commit: {
        operation: "delete",
        collection: "app.bsky.feed.post",
        rkey: "deletedrkey",
      },
    }.to_json

    event = decode(payload)

    assert_equal :delete, event.operation
    assert_equal "deletedrkey", event.rkey
    assert_nil event.text
  end

  def test_post_event_predicate
    payload = {
      did: "did:plc:x",
      time_us: 1,
      kind: "commit",
      commit: {
        operation: "create",
        collection: "app.bsky.feed.post",
        rkey: "r",
        record: { "$type" => "app.bsky.feed.post", text: "hi", createdAt: "2026-01-01T00:00:00Z" },
      },
    }.to_json

    event = decode(payload)
    assert event.post?
    assert event.create?
  end
end
