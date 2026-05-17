require "tempfile"

require_relative "test_helper"
require "tempest/post"
require "tempest/jetstream/decoder"
require "tempest/repl/formatter"
require "tempest/repl/registry"

class TestREPLFormatter < Minitest::Test
  def setup
    @color_before = Tempest::REPL::Formatter.color
    Tempest::REPL::Formatter.color = false
  end

  def teardown
    Tempest::REPL::Formatter.color = @color_before
  end

  def test_post_line_includes_time_and_handle_and_text
    post = Tempest::Post.new(
      uri: "at://x",
      cid: "bafy",
      handle: "alice.bsky.social",
      display_name: "Alice",
      text: "Hello!",
      created_at: "2026-05-15T01:00:00.000Z",
    )

    line = Tempest::REPL::Formatter.post_line(post)
    assert_equal "[10:00] @alice.bsky.social: Hello!", line
  end

  def test_post_line_omits_time_when_created_at_is_nil
    post = Tempest::Post.new(
      uri: "at://x",
      cid: "bafy",
      handle: "alice.bsky.social",
      display_name: nil,
      text: "no time",
      created_at: nil,
    )

    line = Tempest::REPL::Formatter.post_line(post)
    assert_equal "@alice.bsky.social: no time", line
  end

  def test_post_line_with_color_wraps_time_and_handle_in_ansi
    Tempest::REPL::Formatter.color = true
    post = Tempest::Post.new(
      uri: "at://x", cid: "bafy", handle: "alice.bsky.social",
      display_name: nil, text: "hi", created_at: "2026-05-15T01:00:00.000Z",
    )

    line = Tempest::REPL::Formatter.post_line(post)
    assert_includes line, "\e[36m"      # cyan for time
    assert_includes line, "\e[32m"      # green for handle
    assert_includes line, "\e[0m"       # resets
    assert_includes line, "@alice.bsky.social"
  end

  def test_post_line_handles_multiline_text_by_collapsing_newlines
    post = Tempest::Post.new(
      uri: "at://x",
      cid: "bafy",
      handle: "bob.bsky.social",
      display_name: nil,
      text: "line1\nline2",
      created_at: nil,
    )

    line = Tempest::REPL::Formatter.post_line(post)
    assert_equal "@bob.bsky.social: line1 line2", line
  end

  class StubResolver
    def initialize(table = {})
      @table = table
    end
    def resolve(did) = @table[did]
  end

  def test_event_line_uses_resolved_handle_matching_post_line
    event = Tempest::Jetstream::Event.new(
      kind: :commit, did: "did:plc:abc", time_us: 1,
      collection: "app.bsky.feed.post", operation: :create,
      rkey: "r", cid: nil, text: "hello stream", created_at: "2026-01-01T00:00:00Z",
    )

    resolver = StubResolver.new("did:plc:abc" => "alice.bsky.social")

    line = Tempest::REPL::Formatter.event_line(event, resolver: resolver)
    assert_equal "[09:00] @alice.bsky.social: hello stream", line
  end

  def test_event_line_falls_back_to_did_when_handle_unknown
    event = Tempest::Jetstream::Event.new(
      kind: :commit, did: "did:plc:unknown", time_us: 1,
      collection: "app.bsky.feed.post", operation: :create,
      rkey: "r", cid: nil, text: "no handle", created_at: "2026-01-01T00:00:00Z",
    )

    line = Tempest::REPL::Formatter.event_line(event, resolver: StubResolver.new)
    assert_equal "[09:00] <did:plc:unknown>: no handle", line
  end

  def test_event_line_without_resolver_uses_did
    event = Tempest::Jetstream::Event.new(
      kind: :commit, did: "did:plc:x", time_us: 1,
      collection: "app.bsky.feed.post", operation: :create,
      rkey: "r", cid: nil, text: "no resolver", created_at: nil,
    )

    line = Tempest::REPL::Formatter.event_line(event)
    assert_equal "<did:plc:x>: no resolver", line
  end

  def test_event_line_for_like_renders_liked_target_handle
    event = Tempest::Jetstream::Event.new(
      kind: :commit, did: "did:plc:actor", time_us: 1,
      collection: "app.bsky.feed.like", operation: :create,
      rkey: "lk", cid: nil, text: nil, created_at: "2026-01-01T00:00:00Z",
      subject_uri: "at://did:plc:target/app.bsky.feed.post/abc",
    )

    resolver = StubResolver.new(
      "did:plc:actor" => "alice.bsky.social",
      "did:plc:target" => "bob.bsky.social",
    )

    line = Tempest::REPL::Formatter.event_line(event, resolver: resolver)
    assert_equal "[09:00] @alice.bsky.social: liked @bob.bsky.social's post", line
  end

  def test_event_line_for_repost_renders_reposted_target_handle
    event = Tempest::Jetstream::Event.new(
      kind: :commit, did: "did:plc:actor", time_us: 1,
      collection: "app.bsky.feed.repost", operation: :create,
      rkey: "rp", cid: nil, text: nil, created_at: "2026-01-01T00:00:00Z",
      subject_uri: "at://did:plc:target/app.bsky.feed.post/xyz",
    )

    resolver = StubResolver.new(
      "did:plc:actor" => "alice.bsky.social",
      "did:plc:target" => "bob.bsky.social",
    )

    line = Tempest::REPL::Formatter.event_line(event, resolver: resolver)
    assert_equal "[09:00] @alice.bsky.social: reposted @bob.bsky.social's post", line
  end

  def test_event_line_for_like_falls_back_to_did_when_target_unknown
    event = Tempest::Jetstream::Event.new(
      kind: :commit, did: "did:plc:actor", time_us: 1,
      collection: "app.bsky.feed.like", operation: :create,
      rkey: "lk", cid: nil, text: nil, created_at: nil,
      subject_uri: "at://did:plc:target/app.bsky.feed.post/abc",
    )

    resolver = StubResolver.new("did:plc:actor" => "alice.bsky.social")

    line = Tempest::REPL::Formatter.event_line(event, resolver: resolver)
    assert_equal "@alice.bsky.social: liked <did:plc:target>'s post", line
  end

  def test_event_line_for_like_annotates_subject_with_registry_var_when_known
    subject_uri = "at://did:plc:target/app.bsky.feed.post/abc"
    registry = Tempest::REPL::Registry.new
    subject_post = Tempest::Post.new(
      uri: subject_uri, cid: "bafy", handle: "bob.bsky.social",
      display_name: nil, text: "original", created_at: nil,
    )
    assigned_var = registry.assign_post(subject_post)

    event = Tempest::Jetstream::Event.new(
      kind: :commit, did: "did:plc:actor", time_us: 1,
      collection: "app.bsky.feed.like", operation: :create,
      rkey: "lk", cid: nil, text: nil, created_at: "2026-01-01T00:00:00Z",
      subject_uri: subject_uri,
    )
    resolver = StubResolver.new(
      "did:plc:actor" => "alice.bsky.social",
      "did:plc:target" => "bob.bsky.social",
    )

    line = Tempest::REPL::Formatter.event_line(event, registry: registry, resolver: resolver)
    assert_equal "[09:00] @alice.bsky.social: liked @bob.bsky.social's post [#{assigned_var}]", line
  end

  def test_event_line_for_repost_annotates_subject_with_registry_var_when_known
    subject_uri = "at://did:plc:target/app.bsky.feed.post/xyz"
    registry = Tempest::REPL::Registry.new
    subject_post = Tempest::Post.new(
      uri: subject_uri, cid: "bafy", handle: "bob.bsky.social",
      display_name: nil, text: "original", created_at: nil,
    )
    assigned_var = registry.assign_post(subject_post)

    event = Tempest::Jetstream::Event.new(
      kind: :commit, did: "did:plc:actor", time_us: 1,
      collection: "app.bsky.feed.repost", operation: :create,
      rkey: "rp", cid: nil, text: nil, created_at: "2026-01-01T00:00:00Z",
      subject_uri: subject_uri,
    )
    resolver = StubResolver.new(
      "did:plc:actor" => "alice.bsky.social",
      "did:plc:target" => "bob.bsky.social",
    )

    line = Tempest::REPL::Formatter.event_line(event, registry: registry, resolver: resolver)
    assert_equal "[09:00] @alice.bsky.social: reposted @bob.bsky.social's post [#{assigned_var}]", line
  end

  def test_decorate_body_returns_plain_text_when_color_is_off
    text = "check #ruby at https://example.com"
    assert_equal text, Tempest::REPL::Formatter.decorate_body(text)
  end

  def test_decorate_body_wraps_hashtags_in_muted_blue_when_color_is_on
    Tempest::REPL::Formatter.color = true
    decorated = Tempest::REPL::Formatter.decorate_body("hello #ruby world")
    assert_equal "hello \e[38;5;110m#ruby\e[0m world", decorated
  end

  def test_decorate_body_wraps_urls_in_dim_when_color_is_on
    Tempest::REPL::Formatter.color = true
    decorated = Tempest::REPL::Formatter.decorate_body("see https://example.com now")
    assert_equal "see \e[2mhttps://example.com\e[0m now", decorated
  end

  def test_decorate_body_handles_multiple_hashtags
    Tempest::REPL::Formatter.color = true
    decorated = Tempest::REPL::Formatter.decorate_body("#a and #b")
    assert_equal "\e[38;5;110m#a\e[0m and \e[38;5;110m#b\e[0m", decorated
  end

  def test_decorate_body_does_not_treat_url_fragment_as_hashtag
    Tempest::REPL::Formatter.color = true
    decorated = Tempest::REPL::Formatter.decorate_body("see https://example.com/page#section now")
    assert_equal "see \e[2mhttps://example.com/page#section\e[0m now", decorated
  end

  def test_decorate_body_handles_hashtag_and_url_together
    Tempest::REPL::Formatter.color = true
    decorated = Tempest::REPL::Formatter.decorate_body("#ruby https://example.com")
    assert_equal "\e[38;5;110m#ruby\e[0m \e[2mhttps://example.com\e[0m", decorated
  end

  def test_event_line_decorates_hashtag_in_post_body_when_color_is_on
    Tempest::REPL::Formatter.color = true
    event = Tempest::Jetstream::Event.new(
      kind: :commit, did: "did:plc:abc", time_us: 1,
      collection: "app.bsky.feed.post", operation: :create,
      rkey: "r", cid: nil, text: "see #ruby", created_at: nil,
    )

    line = Tempest::REPL::Formatter.event_line(event)
    assert_includes line, "\e[38;5;110m#ruby\e[0m"
  end

  def test_post_line_decorates_hashtag_when_color_is_on
    Tempest::REPL::Formatter.color = true
    post = Tempest::Post.new(
      uri: "at://x", cid: "bafy", handle: "alice.bsky.social",
      display_name: nil, text: "#ruby", created_at: nil,
    )

    line = Tempest::REPL::Formatter.post_line(post)
    assert_includes line, "\e[38;5;110m#ruby\e[0m"
  end

  def test_event_line_for_like_without_subject_uri_renders_generic_message
    event = Tempest::Jetstream::Event.new(
      kind: :commit, did: "did:plc:actor", time_us: 1,
      collection: "app.bsky.feed.like", operation: :create,
      rkey: "lk", cid: nil, text: nil, created_at: nil,
      subject_uri: nil,
    )

    line = Tempest::REPL::Formatter.event_line(event, resolver: StubResolver.new("did:plc:actor" => "alice.bsky.social"))
    assert_equal "@alice.bsky.social: liked a post", line
  end

  def test_post_line_with_registry_prepends_dollar_id_after_time
    post = Tempest::Post.new(
      uri: "at://x/1", cid: "bafy",
      handle: "alice.bsky.social", display_name: nil,
      text: "hi", created_at: "2026-05-15T01:00:00.000Z",
    )
    registry = Tempest::REPL::Registry.new

    line = Tempest::REPL::Formatter.post_line(post, registry: registry)
    assert_equal "[$AA] [10:00] @alice.bsky.social: hi", line
  end

  def test_post_line_with_registry_annotates_urls_with_link_id
    post = Tempest::Post.new(
      uri: "at://x/1", cid: "bafy",
      handle: "alice.bsky.social", display_name: nil,
      text: "see https://example.com and also https://other.test",
      created_at: nil,
    )
    registry = Tempest::REPL::Registry.new

    line = Tempest::REPL::Formatter.post_line(post, registry: registry)
    assert_equal(
      "[$AA] @alice.bsky.social: see https://example.com ($LA) and also https://other.test ($LB)",
      line,
    )
  end

  def test_post_line_without_registry_is_unchanged
    post = Tempest::Post.new(
      uri: "at://x/1", cid: "bafy",
      handle: "alice.bsky.social", display_name: nil,
      text: "see https://example.com", created_at: nil,
    )
    line = Tempest::REPL::Formatter.post_line(post)
    assert_equal "@alice.bsky.social: see https://example.com", line
  end

  def test_event_line_with_registry_prepends_dollar_id_for_post_create
    event = Tempest::Jetstream::Event.new(
      kind: :commit, did: "did:plc:x", time_us: 1,
      collection: "app.bsky.feed.post", operation: :create,
      rkey: "r", cid: "bafy",
      text: "hello stream", created_at: "2026-01-01T00:00:00Z",
    )
    registry = Tempest::REPL::Registry.new

    line = Tempest::REPL::Formatter.event_line(event, registry: registry)
    assert_equal "[$AA] [09:00] <did:plc:x>: hello stream", line
  end

  def test_event_line_with_registry_does_not_assign_id_for_delete
    event = Tempest::Jetstream::Event.new(
      kind: :commit, did: "did:plc:x", time_us: 1,
      collection: "app.bsky.feed.post", operation: :delete,
      rkey: "r", cid: nil, text: nil, created_at: nil,
    )
    registry = Tempest::REPL::Registry.new

    line = Tempest::REPL::Formatter.event_line(event, registry: registry)
    refute_match(/\[\$AA\]/, line)
    # And the registry was not consumed (next post still gets $AA).
    post = Tempest::Post.new(
      uri: "at://x/1", cid: "bafy",
      handle: "h", display_name: nil, text: "t", created_at: nil,
    )
    assert_equal "$AA", registry.assign_post(post)
  end

  def test_post_line_with_registry_uses_facets_to_replace_truncated_url_with_domain_and_id
    # Japanese surrounds the truncated display URL; the facet's byte range
    # covers exactly the truncated form. The replacement must use byte
    # offsets, not character offsets.
    truncated = "www.kelloggs.com/ja-jp/produc..."
    prefix = "イライラする "
    suffix = " 続き"
    text = prefix + truncated + suffix
    byte_start = prefix.bytesize
    byte_end = byte_start + truncated.bytesize

    facet = Tempest::Facet::Link.new(
      byte_start: byte_start,
      byte_end: byte_end,
      uri: "https://www.kelloggs.com/ja-jp/products/some-cereal",
    )
    post = Tempest::Post.new(
      uri: "at://x/1", cid: "bafy",
      handle: "alice.bsky.social", display_name: nil,
      text: text, created_at: nil, facets: [facet],
    )
    registry = Tempest::REPL::Registry.new

    line = Tempest::REPL::Formatter.post_line(post, registry: registry)
    assert_equal(
      "[$AA] @alice.bsky.social: イライラする [www.kelloggs.com $LA] 続き",
      line,
    )
    assert_equal "https://www.kelloggs.com/ja-jp/products/some-cereal",
                 registry.find_url("$LA")
  end

  def test_post_line_with_two_facets_substitutes_each_at_correct_byte_range
    # Pass facets in NON-sorted order to verify the formatter applies them in
    # reverse byte_start order so earlier ranges remain valid.
    a = "https://a.example/aa"
    b = "https://b.example/bb"
    text = "first #{a} mid #{b} end"
    a_start = "first ".bytesize
    a_end = a_start + a.bytesize
    b_start = a_end + " mid ".bytesize
    b_end = b_start + b.bytesize

    facet_b = Tempest::Facet::Link.new(byte_start: b_start, byte_end: b_end, uri: b)
    facet_a = Tempest::Facet::Link.new(byte_start: a_start, byte_end: a_end, uri: a)
    post = Tempest::Post.new(
      uri: "at://x/1", cid: "bafy",
      handle: "alice.bsky.social", display_name: nil,
      text: text, created_at: nil,
      facets: [facet_b, facet_a],
    )
    registry = Tempest::REPL::Registry.new

    line = Tempest::REPL::Formatter.post_line(post, registry: registry)
    assert_equal(
      "[$AA] @alice.bsky.social: first [a.example $LA] mid [b.example $LB] end",
      line,
    )
    assert_equal a, registry.find_url("$LA")
    assert_equal b, registry.find_url("$LB")
  end

  def test_post_line_without_facets_falls_back_to_uri_extract_annotation
    post = Tempest::Post.new(
      uri: "at://x/1", cid: "bafy",
      handle: "alice.bsky.social", display_name: nil,
      text: "see https://example.com",
      created_at: nil,
      facets: [],
    )
    registry = Tempest::REPL::Registry.new

    line = Tempest::REPL::Formatter.post_line(post, registry: registry)
    assert_equal "[$AA] @alice.bsky.social: see https://example.com ($LA)", line
    assert_equal "https://example.com", registry.find_url("$LA")
  end

  def test_event_line_with_facets_substitutes_truncated_url_with_domain_and_id
    text = "see www.kelloggs.com/ja-jp/produc... now"
    byte_start = "see ".bytesize
    byte_end = byte_start + "www.kelloggs.com/ja-jp/produc...".bytesize
    facet = Tempest::Facet::Link.new(
      byte_start: byte_start, byte_end: byte_end,
      uri: "https://www.kelloggs.com/ja-jp/products/some-cereal",
    )
    event = Tempest::Jetstream::Event.new(
      kind: :commit, did: "did:plc:x", time_us: 1,
      collection: "app.bsky.feed.post", operation: :create,
      rkey: "r", cid: "bafy",
      text: text, created_at: nil,
      facets: [facet],
    )
    registry = Tempest::REPL::Registry.new

    line = Tempest::REPL::Formatter.event_line(event, registry: registry)
    assert_equal(
      "[$AA] <did:plc:x>: see [www.kelloggs.com $LA] now",
      line,
    )
    assert_equal "https://www.kelloggs.com/ja-jp/products/some-cereal",
                 registry.find_url("$LA")
  end

  def test_event_line_prefixes_body_with_reply_var_when_parent_in_registry
    parent_post = Tempest::Post.new(
      uri: "at://did:plc:parent/app.bsky.feed.post/parkey", cid: "bafy",
      handle: "bob.bsky.social", display_name: nil, text: "first", created_at: nil,
    )
    registry = Tempest::REPL::Registry.new
    registry.assign_post(parent_post) # gets $AA

    event = Tempest::Jetstream::Event.new(
      kind: :commit, did: "did:plc:replier", time_us: 2,
      collection: "app.bsky.feed.post", operation: :create,
      rkey: "rk", cid: "bafy", text: "thanks", created_at: nil,
      reply_parent_uri: "at://did:plc:parent/app.bsky.feed.post/parkey",
    )

    line = Tempest::REPL::Formatter.event_line(event, registry: registry)
    assert_equal "[$AB] <did:plc:replier>: ↪$AA thanks", line
  end

  def test_event_line_prefixes_body_with_bare_arrow_when_parent_unknown
    registry = Tempest::REPL::Registry.new
    event = Tempest::Jetstream::Event.new(
      kind: :commit, did: "did:plc:replier", time_us: 2,
      collection: "app.bsky.feed.post", operation: :create,
      rkey: "rk", cid: "bafy", text: "thanks", created_at: nil,
      reply_parent_uri: "at://did:plc:other/app.bsky.feed.post/unseen",
    )

    line = Tempest::REPL::Formatter.event_line(event, registry: registry)
    assert_equal "[$AA] <did:plc:replier>: ↪ thanks", line
  end

  def test_event_line_does_not_add_reply_prefix_for_non_reply_post
    registry = Tempest::REPL::Registry.new
    event = Tempest::Jetstream::Event.new(
      kind: :commit, did: "did:plc:replier", time_us: 2,
      collection: "app.bsky.feed.post", operation: :create,
      rkey: "rk", cid: "bafy", text: "hi", created_at: nil,
    )

    line = Tempest::REPL::Formatter.event_line(event, registry: registry)
    assert_equal "[$AA] <did:plc:replier>: hi", line
  end

  def test_post_line_prefixes_body_with_reply_var_when_parent_in_registry
    parent_post = Tempest::Post.new(
      uri: "at://did:plc:parent/app.bsky.feed.post/parkey", cid: "bafy",
      handle: "bob.bsky.social", display_name: nil, text: "first", created_at: nil,
    )
    registry = Tempest::REPL::Registry.new
    registry.assign_post(parent_post)

    reply = Tempest::Post.new(
      uri: "at://did:plc:replier/app.bsky.feed.post/rk", cid: "bafy",
      handle: "alice.bsky.social", display_name: nil,
      text: "thanks", created_at: nil,
      reply_parent_uri: "at://did:plc:parent/app.bsky.feed.post/parkey",
    )

    line = Tempest::REPL::Formatter.post_line(reply, registry: registry)
    assert_equal "[$AB] @alice.bsky.social: ↪$AA thanks", line
  end

  def test_post_line_without_registry_omits_reply_prefix
    reply = Tempest::Post.new(
      uri: "at://x/1", cid: "bafy",
      handle: "alice.bsky.social", display_name: nil,
      text: "thanks", created_at: nil,
      reply_parent_uri: "at://did:plc:parent/app.bsky.feed.post/parkey",
    )

    line = Tempest::REPL::Formatter.post_line(reply)
    assert_equal "@alice.bsky.social: thanks", line
  end

  class StubAvatarStore
    def initialize(table = {})
      @table = table
    end
    def path_for(did) = @table[did]
  end

  # When an avatar store is wired in but it doesn't have a path for this DID,
  # the line must look exactly like today — no leading icon, no stray spaces.
  def test_post_line_with_avatar_store_returning_nil_matches_baseline
    post = Tempest::Post.new(
      uri: "at://did:plc:abc/app.bsky.feed.post/r", cid: "bafy",
      handle: "alice.bsky.social", display_name: nil,
      text: "hi", created_at: "2026-05-15T01:00:00.000Z",
    )
    store = StubAvatarStore.new # path_for returns nil for everything

    line = Tempest::REPL::Formatter.post_line(post, avatar_store: store)
    assert_equal "[10:00] @alice.bsky.social: hi", line
  end

  # Color is off in tests, and we mirror that for icons so existing assertions
  # against exact string output keep passing even with a populated store.
  def test_post_line_omits_icon_when_color_off_even_if_avatar_path_known
    png = Tempfile.new(["avatar", ".png"], binmode: true)
    png.write("\x89PNG\r\n\x1A\n")
    png.close

    post = Tempest::Post.new(
      uri: "at://did:plc:abc/app.bsky.feed.post/r", cid: "bafy",
      handle: "alice.bsky.social", display_name: nil,
      text: "hi", created_at: nil,
    )
    store = StubAvatarStore.new("did:plc:abc" => png.path)

    line = Tempest::REPL::Formatter.post_line(post, avatar_store: store)
    refute_includes line, "\e_G", "icon should be suppressed when color is off: #{line.inspect}"
    assert_equal "@alice.bsky.social: hi", line
  ensure
    png&.close
    png&.unlink
  end

  def test_post_line_injects_kitty_escape_before_handle_when_color_on_and_avatar_known
    Tempest::REPL::Formatter.color = true
    png = Tempfile.new(["avatar", ".png"], binmode: true)
    png.write("\x89PNG\r\n\x1A\n")
    png.close

    post = Tempest::Post.new(
      uri: "at://did:plc:abc/app.bsky.feed.post/r", cid: "bafy",
      handle: "alice.bsky.social", display_name: nil,
      text: "hi", created_at: nil,
    )
    store = StubAvatarStore.new("did:plc:abc" => png.path)

    line = Tempest::REPL::Formatter.post_line(post, avatar_store: store)

    assert_includes line, "\e_G", "expected a Kitty graphics escape in: #{line.inspect}"
    assert_includes line, "@alice.bsky.social"
    icon_index = line.index("\e_G")
    handle_index = line.index("@alice.bsky.social")
    assert_operator icon_index, :<, handle_index,
      "icon should come before the handle in: #{line.inspect}"
    # Exactly one space sits between the icon's trailing ESC\ and the handle's
    # ANSI green prefix.
    assert_match(/\e\\\s\e\[32m@alice\.bsky\.social/, line)
  ensure
    png&.close
    png&.unlink
  end

  def test_event_line_injects_kitty_escape_before_handle_when_avatar_known
    Tempest::REPL::Formatter.color = true
    png = Tempfile.new(["avatar", ".png"], binmode: true)
    png.write("\x89PNG\r\n\x1A\n")
    png.close

    event = Tempest::Jetstream::Event.new(
      kind: :commit, did: "did:plc:abc", time_us: 1,
      collection: "app.bsky.feed.post", operation: :create,
      rkey: "r", cid: nil, text: "hi stream", created_at: nil,
    )
    resolver = StubResolver.new("did:plc:abc" => "alice.bsky.social")
    store = StubAvatarStore.new("did:plc:abc" => png.path)

    line = Tempest::REPL::Formatter.event_line(event, resolver: resolver, avatar_store: store)

    assert_includes line, "\e_G"
    assert_match(/\e\\\s\e\[32m@alice\.bsky\.social/, line)
  ensure
    png&.close
    png&.unlink
  end

  def test_event_line_with_registry_does_not_assign_id_for_like
    event = Tempest::Jetstream::Event.new(
      kind: :commit, did: "did:plc:actor", time_us: 1,
      collection: "app.bsky.feed.like", operation: :create,
      rkey: "lk", cid: nil, text: nil, created_at: nil,
      subject_uri: "at://did:plc:target/app.bsky.feed.post/abc",
    )
    registry = Tempest::REPL::Registry.new

    line = Tempest::REPL::Formatter.event_line(event, registry: registry)
    refute_match(/\[\$AA\]/, line)
  end
end
