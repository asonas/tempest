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

  def test_from_feed_view_classifies_images_embed_as_images
    raw = base_feed_view
    raw["record"]["embed"] = { "$type" => "app.bsky.embed.images" }
    post = Tempest::Post.from_feed_view(raw)
    assert_equal :images, post.embed_kind
  end

  def test_from_feed_view_classifies_video_embed_as_video
    raw = base_feed_view
    raw["record"]["embed"] = { "$type" => "app.bsky.embed.video" }
    post = Tempest::Post.from_feed_view(raw)
    assert_equal :video, post.embed_kind
  end

  def test_from_feed_view_returns_nil_embed_kind_for_record_quote
    raw = base_feed_view
    raw["record"]["embed"] = { "$type" => "app.bsky.embed.record" }
    post = Tempest::Post.from_feed_view(raw)
    assert_nil post.embed_kind
  end

  def test_from_feed_view_returns_nil_embed_kind_for_external_link
    raw = base_feed_view
    raw["record"]["embed"] = { "$type" => "app.bsky.embed.external" }
    post = Tempest::Post.from_feed_view(raw)
    assert_nil post.embed_kind
  end

  def test_from_feed_view_returns_nil_embed_kind_when_record_has_no_embed
    post = Tempest::Post.from_feed_view(base_feed_view)
    assert_nil post.embed_kind
  end

  def test_from_feed_view_classifies_images_view_variant_from_top_level_embed
    raw = base_feed_view
    raw["embed"] = { "$type" => "app.bsky.embed.images#view" }
    post = Tempest::Post.from_feed_view(raw)
    assert_equal :images, post.embed_kind
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

  def test_create_with_reply_writes_root_and_parent_from_refs
    client = FakeClient.new("uri" => "at://did:plc:abc/app.bsky.feed.post/zzz")

    Tempest::Post.create(
      client,
      did: "did:plc:abc",
      text: "@bob hi",
      reply: {
        root:   { uri: "at://did:plc:carol/app.bsky.feed.post/root", cid: "bafyroot" },
        parent: { uri: "at://did:plc:bob/app.bsky.feed.post/parent", cid: "bafyparent" },
      },
      created_at: "2026-05-15T00:00:00.000Z",
    )

    _, body = client.calls.first
    record = body[:record]
    assert_equal(
      { "uri" => "at://did:plc:carol/app.bsky.feed.post/root", "cid" => "bafyroot" },
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

  def test_create_attaches_mention_facet_for_handle_in_text
    client = FakeClient.new("uri" => "at://x")
    def client.get(_nsid, query:)
      raise "unexpected actor" unless query["actor"] == "alice.bsky.social"
      { "did" => "did:plc:alice", "handle" => "alice.bsky.social" }
    end
    Tempest::Post.create(client, did: "did:plc:abc", text: "hi @alice.bsky.social")

    _, body = client.calls.first
    facets = body[:record]["facets"]
    assert_equal 1, facets.length
    facet = facets.first
    expected_start = "hi ".bytesize
    expected_end   = expected_start + "@alice.bsky.social".bytesize
    assert_equal expected_start, facet["index"]["byteStart"]
    assert_equal expected_end,   facet["index"]["byteEnd"]
    assert_equal "app.bsky.richtext.facet#mention", facet["features"].first["$type"]
    assert_equal "did:plc:alice", facet["features"].first["did"]
  end

  def test_create_merges_mention_and_link_facets_in_byte_order
    client = FakeClient.new("uri" => "at://x")
    def client.get(_nsid, query:)
      { "did" => "did:plc:alice", "handle" => query["actor"] }
    end
    text = "@alice.bsky.social check https://example.com"
    Tempest::Post.create(client, did: "did:plc:abc", text: text)

    _, body = client.calls.first
    facets = body[:record]["facets"]
    assert_equal 2, facets.length
    assert facets[0]["index"]["byteStart"] < facets[1]["index"]["byteStart"]
    types = facets.map { |f| f["features"].first["$type"] }
    assert_includes types, "app.bsky.richtext.facet#mention"
    assert_includes types, "app.bsky.richtext.facet#link"
  end

  def test_create_attaches_tag_facet_for_hashtag_in_text
    client = FakeClient.new("uri" => "at://x")
    text = "handy timeline #sekigahara01"
    Tempest::Post.create(client, did: "did:plc:abc", text: text)

    _, body = client.calls.first
    facets = body[:record]["facets"]
    assert_equal 1, facets.length
    facet = facets.first
    expected_start = "handy timeline ".bytesize
    assert_equal expected_start, facet["index"]["byteStart"]
    assert_equal expected_start + "#sekigahara01".bytesize, facet["index"]["byteEnd"]
    assert_equal "app.bsky.richtext.facet#tag", facet["features"].first["$type"]
    assert_equal "sekigahara01", facet["features"].first["tag"]
  end

  def test_create_merges_tag_with_link_facets_in_byte_order
    client = FakeClient.new("uri" => "at://x")
    text = "#ruby see https://example.com"
    Tempest::Post.create(client, did: "did:plc:abc", text: text)

    _, body = client.calls.first
    facets = body[:record]["facets"]
    assert_equal 2, facets.length
    assert facets[0]["index"]["byteStart"] < facets[1]["index"]["byteStart"]
    types = facets.map { |f| f["features"].first["$type"] }
    assert_equal ["app.bsky.richtext.facet#tag", "app.bsky.richtext.facet#link"], types
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

  def test_create_writes_langs_into_record
    client = FakeClient.new("uri" => "at://x")
    Tempest::Post.create(client, did: "did:plc:abc", text: "hi", langs: ["ja", "en"])
    _, body = client.calls.first
    assert_equal ["ja", "en"], body[:record]["langs"]
  end

  def test_create_omits_langs_when_not_given
    client = FakeClient.new("uri" => "at://x")
    Tempest::Post.create(client, did: "did:plc:abc", text: "hi")
    _, body = client.calls.first
    refute body[:record].key?("langs")
  end
end

class TestPostLike < Minitest::Test
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

  def test_like_calls_create_record_with_like_record_pointing_at_subject
    client = FakeClient.new(
      "uri" => "at://did:plc:abc/app.bsky.feed.like/rkey",
      "cid" => "bafylike",
    )

    response = Tempest::Post.like(
      client,
      did: "did:plc:abc",
      subject_uri: "at://did:plc:author/app.bsky.feed.post/target",
      subject_cid: "bafytarget",
      created_at: "2026-05-15T00:00:00.000Z",
    )

    assert_equal 1, client.calls.length
    nsid, body = client.calls.first
    assert_equal "com.atproto.repo.createRecord", nsid
    assert_equal "did:plc:abc", body[:repo]
    assert_equal "app.bsky.feed.like", body[:collection]
    record = body[:record]
    assert_equal "app.bsky.feed.like", record["$type"]
    assert_equal "2026-05-15T00:00:00.000Z", record["createdAt"]
    assert_equal "at://did:plc:author/app.bsky.feed.post/target", record["subject"]["uri"]
    assert_equal "bafytarget", record["subject"]["cid"]
    assert_equal "at://did:plc:abc/app.bsky.feed.like/rkey", response["uri"]
  end

  def test_like_defaults_created_at_to_now_in_iso8601_utc
    client = FakeClient.new("uri" => "at://x")
    Tempest::Post.like(
      client,
      did: "did:plc:abc",
      subject_uri: "at://did:plc:author/app.bsky.feed.post/y",
      subject_cid: "bafy",
    )
    _, body = client.calls.first
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/, body[:record]["createdAt"])
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

class TestPostDetectMentionFacets < Minitest::Test
  class FakeClient
    attr_reader :get_calls
    def initialize(profiles: {})
      @profiles = profiles
      @get_calls = []
    end
    def get(nsid, query: nil)
      @get_calls << [nsid, query]
      raise "unexpected #{nsid}" unless nsid == "app.bsky.actor.getProfile"
      actor = query["actor"]
      raise Tempest::APIError.new(400, "InvalidRequest") unless @profiles.key?(actor)
      { "did" => @profiles.fetch(actor), "handle" => actor }
    end
  end

  def test_resolves_single_mention_to_mention_facet
    client = FakeClient.new(profiles: { "alice.bsky.social" => "did:plc:alice" })
    text = "@alice.bsky.social hi"
    facets = Tempest::Post.detect_mention_facets(text, client: client)

    assert_equal 1, facets.length
    facet = facets.first
    assert_equal 0, facet["index"]["byteStart"]
    assert_equal "@alice.bsky.social".bytesize, facet["index"]["byteEnd"]
    feature = facet["features"].first
    assert_equal "app.bsky.richtext.facet#mention", feature["$type"]
    assert_equal "did:plc:alice", feature["did"]
  end

  def test_detects_mention_after_whitespace_or_open_bracket
    client = FakeClient.new(profiles: {
      "alice.bsky.social" => "did:plc:alice",
      "bob.bsky.social"   => "did:plc:bob",
    })
    text = "hi @alice.bsky.social (@bob.bsky.social)"
    facets = Tempest::Post.detect_mention_facets(text, client: client)
    assert_equal 2, facets.length
    assert_equal "did:plc:alice", facets[0]["features"].first["did"]
    assert_equal "did:plc:bob",   facets[1]["features"].first["did"]
  end

  def test_uses_byte_offsets_after_multibyte_text
    client = FakeClient.new(profiles: { "alice.bsky.social" => "did:plc:alice" })
    text = "見て @alice.bsky.social ね"
    facets = Tempest::Post.detect_mention_facets(text, client: client)
    expected_start = "見て ".bytesize
    expected_end = expected_start + "@alice.bsky.social".bytesize
    assert_equal expected_start, facets.first["index"]["byteStart"]
    assert_equal expected_end,   facets.first["index"]["byteEnd"]
  end

  def test_skips_mention_when_handle_does_not_resolve
    client = FakeClient.new(profiles: {})  # no profiles known
    facets = Tempest::Post.detect_mention_facets("@ghost.bsky.social hi", client: client)
    assert_empty facets
  end

  def test_skips_get_profile_when_text_has_no_at_sign
    client = FakeClient.new(profiles: {})
    facets = Tempest::Post.detect_mention_facets("plain text", client: client)
    assert_empty facets
    assert_empty client.get_calls
  end

  def test_ignores_bare_at_without_domain
    client = FakeClient.new(profiles: {})
    facets = Tempest::Post.detect_mention_facets("email me at @work tomorrow", client: client)
    assert_empty facets
    assert_empty client.get_calls
  end
end

class TestPostDetectTagFacets < Minitest::Test
  def test_detects_single_hashtag
    text = "tempest is handy #sekigahara01"
    facets = Tempest::Post.detect_tag_facets(text)

    assert_equal 1, facets.length
    facet = facets.first
    expected_start = "tempest is handy ".bytesize
    expected_end = expected_start + "#sekigahara01".bytesize
    assert_equal expected_start, facet["index"]["byteStart"]
    assert_equal expected_end,   facet["index"]["byteEnd"]
    feature = facet["features"].first
    assert_equal "app.bsky.richtext.facet#tag", feature["$type"]
    assert_equal "sekigahara01", feature["tag"]
  end

  def test_uses_byte_offsets_after_multibyte_text
    text = "会場のインターネットが細くても快適 #sekigahara01"
    facets = Tempest::Post.detect_tag_facets(text)

    assert_equal 1, facets.length
    expected_start = "会場のインターネットが細くても快適 ".bytesize
    expected_end = expected_start + "#sekigahara01".bytesize
    assert_equal expected_start, facets.first["index"]["byteStart"]
    assert_equal expected_end,   facets.first["index"]["byteEnd"]
    assert_equal "sekigahara01", facets.first["features"].first["tag"]
  end

  def test_detects_multibyte_tag
    text = "今年も #関ヶ原 に行く"
    facets = Tempest::Post.detect_tag_facets(text)

    assert_equal 1, facets.length
    expected_start = "今年も ".bytesize
    expected_end = expected_start + "#関ヶ原".bytesize
    assert_equal expected_start, facets.first["index"]["byteStart"]
    assert_equal expected_end,   facets.first["index"]["byteEnd"]
    assert_equal "関ヶ原", facets.first["features"].first["tag"]
  end

  def test_detects_multiple_hashtags
    facets = Tempest::Post.detect_tag_facets("#ruby and #bluesky")
    assert_equal %w[ruby bluesky], facets.map { |f| f["features"].first["tag"] }
  end

  def test_detects_hashtag_at_start_of_text
    facets = Tempest::Post.detect_tag_facets("#hello world")
    assert_equal 1, facets.length
    assert_equal 0, facets.first["index"]["byteStart"]
    assert_equal "#hello".bytesize, facets.first["index"]["byteEnd"]
  end

  def test_strips_trailing_punctuation_from_tag
    facets = Tempest::Post.detect_tag_facets("nice #bluesky!")
    assert_equal 1, facets.length
    assert_equal "bluesky", facets.first["features"].first["tag"]
    expected_start = "nice ".bytesize
    assert_equal expected_start + "#bluesky".bytesize, facets.first["index"]["byteEnd"]
  end

  def test_ignores_numeric_only_tag
    assert_empty Tempest::Post.detect_tag_facets("count #123 things")
  end

  def test_ignores_hash_not_preceded_by_whitespace
    assert_empty Tempest::Post.detect_tag_facets("the language C# is old")
  end

  def test_supports_fullwidth_hash
    facets = Tempest::Post.detect_tag_facets("和風 ＃関ヶ原")
    assert_equal 1, facets.length
    assert_equal "関ヶ原", facets.first["features"].first["tag"]
  end

  def test_skips_tag_longer_than_64_graphemes
    long = "a" * 65
    assert_empty Tempest::Post.detect_tag_facets("x ##{long}")
  end

  def test_returns_empty_when_text_has_no_hash
    assert_empty Tempest::Post.detect_tag_facets("plain text only")
  end
end

class TestPostFetchReplyRefs < Minitest::Test
  class FakeClient
    attr_reader :queries
    def initialize(record)
      @record = record
      @queries = []
    end
    def get(nsid, query: nil)
      raise "unexpected #{nsid}" unless nsid == "com.atproto.repo.getRecord"
      @queries << query
      @record
    end
  end

  def test_returns_parent_as_root_when_parent_is_top_level
    record = {
      "uri" => "at://did:plc:bob/app.bsky.feed.post/par",
      "cid" => "bafyparent",
      "value" => { "$type" => "app.bsky.feed.post", "text" => "hi" },
    }
    refs = Tempest::Post.fetch_reply_refs(FakeClient.new(record),
                                          "at://did:plc:bob/app.bsky.feed.post/par")
    expected = { uri: "at://did:plc:bob/app.bsky.feed.post/par", cid: "bafyparent" }
    assert_equal expected, refs[:root]
    assert_equal expected, refs[:parent]
  end

  def test_inherits_root_when_parent_is_itself_a_reply
    record = {
      "uri" => "at://did:plc:bob/app.bsky.feed.post/par",
      "cid" => "bafyparent",
      "value" => {
        "$type" => "app.bsky.feed.post",
        "reply" => {
          "root"   => { "uri" => "at://did:plc:carol/app.bsky.feed.post/rt", "cid" => "bafyroot" },
          "parent" => { "uri" => "at://did:plc:dave/app.bsky.feed.post/mid", "cid" => "bafymid" },
        },
      },
    }
    refs = Tempest::Post.fetch_reply_refs(FakeClient.new(record),
                                          "at://did:plc:bob/app.bsky.feed.post/par")
    assert_equal({ uri: "at://did:plc:carol/app.bsky.feed.post/rt", cid: "bafyroot" }, refs[:root])
    assert_equal({ uri: "at://did:plc:bob/app.bsky.feed.post/par", cid: "bafyparent" }, refs[:parent])
  end

  def test_passes_repo_collection_rkey_to_get_record
    record = { "uri" => "u", "cid" => "c", "value" => {} }
    client = FakeClient.new(record)
    Tempest::Post.fetch_reply_refs(client, "at://did:plc:bob/app.bsky.feed.post/par")
    query = client.queries.first
    assert_equal "did:plc:bob", query["repo"]
    assert_equal "app.bsky.feed.post", query["collection"]
    assert_equal "par", query["rkey"]
  end

  def test_raises_on_malformed_uri
    assert_raises(ArgumentError) do
      Tempest::Post.fetch_reply_refs(FakeClient.new({}), "not-an-at-uri")
    end
  end
end

class TestPostBskyUrl < Minitest::Test
  def test_uses_handle_when_given
    url = Tempest::Post.bsky_url(
      at_uri: "at://did:plc:abc/app.bsky.feed.post/k1",
      handle: "asonas.bsky.social",
    )
    assert_equal "https://bsky.app/profile/asonas.bsky.social/post/k1", url
  end

  def test_falls_back_to_did_when_handle_missing
    url = Tempest::Post.bsky_url(
      at_uri: "at://did:plc:abc/app.bsky.feed.post/k1",
    )
    assert_equal "https://bsky.app/profile/did:plc:abc/post/k1", url
  end

  def test_falls_back_to_did_when_handle_is_empty_string
    url = Tempest::Post.bsky_url(
      at_uri: "at://did:plc:abc/app.bsky.feed.post/k1",
      handle: "",
    )
    assert_equal "https://bsky.app/profile/did:plc:abc/post/k1", url
  end

  def test_returns_nil_for_non_post_at_uri
    assert_nil Tempest::Post.bsky_url(at_uri: "at://did:plc:abc/app.bsky.feed.like/k1")
    assert_nil Tempest::Post.bsky_url(at_uri: "not-an-at-uri")
    assert_nil Tempest::Post.bsky_url(at_uri: nil)
  end
end
