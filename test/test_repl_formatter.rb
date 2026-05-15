require_relative "test_helper"
require "tempest/post"
require "tempest/repl/formatter"

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
    assert_equal "[01:00] @alice.bsky.social: Hello!", line
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
    assert_equal "[00:00] @alice.bsky.social: hello stream", line
  end

  def test_event_line_falls_back_to_did_when_handle_unknown
    event = Tempest::Jetstream::Event.new(
      kind: :commit, did: "did:plc:unknown", time_us: 1,
      collection: "app.bsky.feed.post", operation: :create,
      rkey: "r", cid: nil, text: "no handle", created_at: "2026-01-01T00:00:00Z",
    )

    line = Tempest::REPL::Formatter.event_line(event, resolver: StubResolver.new)
    assert_equal "[00:00] <did:plc:unknown>: no handle", line
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
end
