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

  def test_create_attaches_link_facet_for_url_in_text
    client = FakeClient.new("uri" => "at://x")
    Tempest::Post.create(client, did: "did:plc:abc", text: "see https://example.com")

    _, body = client.calls.first
    facets = body[:record]["facets"]
    assert_equal 1, facets.length
    facet = facets.first
    assert_equal 4, facet["index"]["byteStart"]
    assert_equal "see https://example.com".bytesize, facet["index"]["byteEnd"]
    assert_equal "app.bsky.richtext.facet#link", facet["features"].first["$type"]
    assert_equal "https://example.com", facet["features"].first["uri"]
  end

  def test_create_omits_facets_when_text_has_no_url
    client = FakeClient.new("uri" => "at://x")
    Tempest::Post.create(client, did: "did:plc:abc", text: "no url here")
    _, body = client.calls.first
    refute body[:record].key?("facets")
  end

  def test_create_attaches_one_facet_per_url
    client = FakeClient.new("uri" => "at://x")
    Tempest::Post.create(
      client, did: "did:plc:abc",
      text: "a https://a.example/x b https://b.example/y c",
    )

    _, body = client.calls.first
    facets = body[:record]["facets"]
    assert_equal 2, facets.length
    assert_equal "https://a.example/x", facets[0]["features"].first["uri"]
    assert_equal "https://b.example/y", facets[1]["features"].first["uri"]
  end

  def test_create_uses_byte_offsets_for_url_after_multibyte_text
    text = "見て https://example.com いいよね"
    client = FakeClient.new("uri" => "at://x")
    Tempest::Post.create(client, did: "did:plc:abc", text: text)

    _, body = client.calls.first
    facet = body[:record]["facets"].first
    expected_start = "見て ".bytesize
    expected_end = expected_start + "https://example.com".bytesize
    assert_equal expected_start, facet["index"]["byteStart"]
    assert_equal expected_end, facet["index"]["byteEnd"]
  end
end

class TestPostFromFeedView < Minitest::Test
  def test_extracts_reply_parent_uri_from_record
    raw = {
      "uri" => "at://did:plc:replier/app.bsky.feed.post/rk",
      "cid" => "bafy",
      "author" => { "handle" => "alice.bsky.social", "displayName" => "Alice" },
      "record" => {
        "$type" => "app.bsky.feed.post",
        "text" => "thanks!",
        "createdAt" => "2026-05-15T00:00:00.000Z",
        "reply" => {
          "root"   => { "uri" => "at://did:plc:root/app.bsky.feed.post/rootkey",   "cid" => "bafyroot" },
          "parent" => { "uri" => "at://did:plc:parent/app.bsky.feed.post/parkey", "cid" => "bafyparent" },
        },
      },
    }

    post = Tempest::Post.from_feed_view(raw)
    assert_equal "at://did:plc:parent/app.bsky.feed.post/parkey", post.reply_parent_uri
  end

  def test_top_level_post_has_nil_reply_parent_uri
    raw = {
      "uri" => "at://did:plc:x/app.bsky.feed.post/r",
      "cid" => "bafy",
      "author" => { "handle" => "bob.bsky.social" },
      "record" => { "$type" => "app.bsky.feed.post", "text" => "top", "createdAt" => "2026-05-15T00:00:00.000Z" },
    }
    post = Tempest::Post.from_feed_view(raw)
    assert_nil post.reply_parent_uri
  end
end
