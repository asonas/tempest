require_relative "../test_helper"
require "stringio"
require "tempest/output/line_writer"
require "tempest/post"

class TestLineWriter < Minitest::Test
  def post
    Tempest::Post.new(
      uri: "at://x", cid: "bafy", handle: "alice.bsky.social",
      display_name: "Alice", text: "hello world",
      created_at: "2026-05-17T01:00:00.000Z",
    )
  end

  def test_write_posts_emits_one_line_per_post_via_formatter
    Tempest::REPL::Formatter.color = false
    io = StringIO.new
    Tempest::Output::LineWriter.new(io).write_posts([post, post])
    assert_equal 2, io.string.lines.length
    assert_match(/@alice.bsky.social: hello world/, io.string.lines.first)
  end

  def test_write_error_writes_error_prefix_line
    io = StringIO.new
    Tempest::Output::LineWriter.new(io).write_error("kaboom", code: "x")
    assert_equal "error: kaboom\n", io.string
  end
end
