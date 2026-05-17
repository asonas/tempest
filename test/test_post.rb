require_relative "test_helper"
require "tempest/post"

class TestPostFromFeedView < Minitest::Test
  def base_feed_view(record_overrides = {})
    {
      "uri" => "at://x",
      "cid" => "bafy",
      "author" => { "handle" => "alice.bsky.social", "displayName" => "Alice" },
      "record" => {
        "text" => "hello",
        "createdAt" => "2026-05-15T01:00:00.000Z",
      }.merge(record_overrides),
    }
  end

  def test_from_feed_view_returns_empty_facets_when_record_has_none
    post = Tempest::Post.from_feed_view(base_feed_view)
    assert_equal [], post.facets
  end

  def test_from_feed_view_parses_link_facet_into_facet_link_entry
    facets = [
      {
        "index" => { "byteStart" => 6, "byteEnd" => 25 },
        "features" => [
          { "$type" => "app.bsky.richtext.facet#link",
            "uri" => "https://www.kelloggs.com/ja-jp/products/some-cereal" },
        ],
      },
    ]
    post = Tempest::Post.from_feed_view(base_feed_view("facets" => facets))

    assert_equal 1, post.facets.length
    facet = post.facets.first
    assert_kind_of Tempest::Facet::Link, facet
    assert_equal 6, facet.byte_start
    assert_equal 25, facet.byte_end
    assert_equal "https://www.kelloggs.com/ja-jp/products/some-cereal", facet.uri
  end

  def test_from_feed_view_drops_non_link_facet_features
    facets = [
      {
        "index" => { "byteStart" => 0, "byteEnd" => 5 },
        "features" => [
          { "$type" => "app.bsky.richtext.facet#mention", "did" => "did:plc:x" },
        ],
      },
      {
        "index" => { "byteStart" => 6, "byteEnd" => 11 },
        "features" => [
          { "$type" => "app.bsky.richtext.facet#tag", "tag" => "ruby" },
        ],
      },
      {
        "index" => { "byteStart" => 12, "byteEnd" => 30 },
        "features" => [
          { "$type" => "app.bsky.richtext.facet#link", "uri" => "https://example.com" },
        ],
      },
    ]
    post = Tempest::Post.from_feed_view(base_feed_view("facets" => facets))

    assert_equal 1, post.facets.length
    assert_equal "https://example.com", post.facets.first.uri
  end

  def test_from_feed_view_defaults_facets_when_record_is_missing
    post = Tempest::Post.from_feed_view({})
    assert_equal [], post.facets
  end
end

class TestPostCreate < Minitest::Test
  class FakeClient
    attr_reader :calls

    def initialize(response = {})
      @response = response
      @calls = []
    end

    def post(nsid, body:)
      @calls << [nsid, body]
      @response
    end
  end

  def test_create_calls_create_record_with_post_record
    client = FakeClient.new(
      "uri" => "at://did:plc:abc/app.bsky.feed.post/xxx",
      "cid" => "bafy",
    )

    response = Tempest::Post.create(
      client,
      did: "did:plc:abc",
      text: "Hello, world!",
      created_at: "2026-05-15T00:00:00.000Z",
    )

    assert_equal 1, client.calls.length
    nsid, body = client.calls.first
    assert_equal "com.atproto.repo.createRecord", nsid
    assert_equal "did:plc:abc", body[:repo]
    assert_equal "app.bsky.feed.post", body[:collection]
    assert_equal "app.bsky.feed.post", body[:record]["$type"]
    assert_equal "Hello, world!", body[:record]["text"]
    assert_equal "2026-05-15T00:00:00.000Z", body[:record]["createdAt"]
    assert_equal "at://did:plc:abc/app.bsky.feed.post/xxx", response["uri"]
  end

  def test_create_defaults_created_at_to_now_in_iso8601_utc
    client = FakeClient.new("uri" => "at://did:plc:abc/app.bsky.feed.post/yyy")

    Tempest::Post.create(client, did: "did:plc:abc", text: "auto")

    _, body = client.calls.first
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/, body[:record]["createdAt"])
  end

  def test_create_with_reply_includes_root_and_parent_equal_to_target
    client = FakeClient.new("uri" => "at://did:plc:abc/app.bsky.feed.post/zzz")

    Tempest::Post.create(
      client,
      did: "did:plc:abc",
      text: "@bob hi",
      reply: { uri: "at://did:plc:bob/app.bsky.feed.post/parent",
               cid: "bafyparent" },
      created_at: "2026-05-15T00:00:00.000Z",
    )

    _, body = client.calls.first
    record = body[:record]
    assert_equal(
      { "uri" => "at://did:plc:bob/app.bsky.feed.post/parent", "cid" => "bafyparent" },
      record["reply"]["root"],
    )
    assert_equal(
      { "uri" => "at://did:plc:bob/app.bsky.feed.post/parent", "cid" => "bafyparent" },
      record["reply"]["parent"],
    )
  end

  def test_create_without_reply_does_not_set_reply_field
    client = FakeClient.new("uri" => "at://x")
    Tempest::Post.create(client, did: "did:plc:abc", text: "plain")
    _, body = client.calls.first
    refute body[:record].key?("reply")
  end
end
