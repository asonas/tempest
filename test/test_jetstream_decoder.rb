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
    refute event.like?
    refute event.repost?
  end

  def test_decode_returns_event_for_like_create_with_subject_uri
    payload = {
      did: "did:plc:actor",
      time_us: 2,
      kind: "commit",
      commit: {
        operation: "create",
        collection: "app.bsky.feed.like",
        rkey: "likekey",
        record: {
          "$type" => "app.bsky.feed.like",
          createdAt: "2026-01-01T00:00:00Z",
          subject: {
            uri: "at://did:plc:target/app.bsky.feed.post/abc",
            cid: "bafytarget",
          },
        },
      },
    }.to_json

    event = decode(payload)

    refute_nil event
    assert_equal "app.bsky.feed.like", event.collection
    assert event.like?
    refute event.post?
    refute event.repost?
    assert_equal "at://did:plc:target/app.bsky.feed.post/abc", event.subject_uri
  end

  def test_decode_returns_event_for_repost_create_with_subject_uri
    payload = {
      did: "did:plc:actor",
      time_us: 3,
      kind: "commit",
      commit: {
        operation: "create",
        collection: "app.bsky.feed.repost",
        rkey: "repkey",
        record: {
          "$type" => "app.bsky.feed.repost",
          createdAt: "2026-01-01T00:00:00Z",
          subject: {
            uri: "at://did:plc:target/app.bsky.feed.post/xyz",
            cid: "bafytarget",
          },
        },
      },
    }.to_json

    event = decode(payload)

    refute_nil event
    assert_equal "app.bsky.feed.repost", event.collection
    assert event.repost?
    refute event.like?
    assert_equal "at://did:plc:target/app.bsky.feed.post/xyz", event.subject_uri
  end

  def test_decode_returns_nil_subject_uri_for_post_records
    payload = {
      did: "did:plc:x",
      time_us: 4,
      kind: "commit",
      commit: {
        operation: "create",
        collection: "app.bsky.feed.post",
        rkey: "r",
        record: { "$type" => "app.bsky.feed.post", text: "hi", createdAt: "2026-01-01T00:00:00Z" },
      },
    }.to_json

    event = decode(payload)
    assert_nil event.subject_uri
  end

  def test_decode_parses_link_facets_from_post_record
    payload = {
      did: "did:plc:x",
      time_us: 5,
      kind: "commit",
      commit: {
        operation: "create",
        collection: "app.bsky.feed.post",
        rkey: "r",
        record: {
          "$type" => "app.bsky.feed.post",
          text: "see kelloggs",
          createdAt: "2026-01-01T00:00:00Z",
          facets: [
            {
              index: { byteStart: 4, byteEnd: 12 },
              features: [
                { "$type" => "app.bsky.richtext.facet#link",
                  uri: "https://www.kelloggs.com/full-path" },
              ],
            },
          ],
        },
      },
    }.to_json

    event = decode(payload)
    assert_equal 1, event.facets.length
    facet = event.facets.first
    assert_kind_of Tempest::Facet::Link, facet
    assert_equal 4, facet.byte_start
    assert_equal 12, facet.byte_end
    assert_equal "https://www.kelloggs.com/full-path", facet.uri
  end

  def test_decode_defaults_facets_to_empty_when_record_has_none
    payload = {
      did: "did:plc:x",
      time_us: 6,
      kind: "commit",
      commit: {
        operation: "create",
        collection: "app.bsky.feed.post",
        rkey: "r",
        record: { "$type" => "app.bsky.feed.post", text: "no facets", createdAt: nil },
      },
    }.to_json

    event = decode(payload)
    assert_equal [], event.facets
  end

  def test_decode_drops_non_link_facet_features
    payload = {
      did: "did:plc:x",
      time_us: 7,
      kind: "commit",
      commit: {
        operation: "create",
        collection: "app.bsky.feed.post",
        rkey: "r",
        record: {
          "$type" => "app.bsky.feed.post",
          text: "hi",
          createdAt: nil,
          facets: [
            {
              index: { byteStart: 0, byteEnd: 2 },
              features: [
                { "$type" => "app.bsky.richtext.facet#tag", tag: "ruby" },
              ],
            },
          ],
        },
      },
    }.to_json

    event = decode(payload)
    assert_equal [], event.facets
  end

  def test_event_at_uri_concatenates_did_collection_and_rkey
    event = Tempest::Jetstream::Event.new(
      kind: :commit, did: "did:plc:x", time_us: 1,
      collection: "app.bsky.feed.post", operation: :create,
      rkey: "abc", cid: nil, text: nil, created_at: nil,
    )
    assert_equal "at://did:plc:x/app.bsky.feed.post/abc", event.at_uri
  end
end
