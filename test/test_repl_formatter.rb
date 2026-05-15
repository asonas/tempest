require_relative "test_helper"
require "tempest/post"
require "tempest/repl/formatter"

class TestREPLFormatter < Minitest::Test
  def test_post_line_uses_handle_and_text
    post = Tempest::Post.new(
      uri: "at://x",
      cid: "bafy",
      handle: "alice.bsky.social",
      display_name: "Alice",
      text: "Hello!",
      created_at: "2026-05-15T01:00:00.000Z",
    )

    line = Tempest::REPL::Formatter.post_line(post)
    assert_equal "@alice.bsky.social: Hello!", line
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
end
