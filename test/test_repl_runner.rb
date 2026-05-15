require_relative "test_helper"
require "stringio"
require "tempest/post"
require "tempest/repl/runner"

class TestREPLRunner < Minitest::Test
  class FakeSession
    attr_reader :did, :handle

    def initialize
      @did = "did:plc:abc"
      @handle = "asonas.bsky.social"
    end
  end

  class FakeXRPCClient
    attr_reader :timeline_calls, :post_calls

    def initialize
      @timeline_calls = 0
      @post_calls = []
    end

    def get(nsid, query: nil)
      @timeline_calls += 1 if nsid == "app.bsky.feed.getTimeline"
      {
        "feed" => [
          {
            "post" => {
              "uri" => "at://did:plc:a/app.bsky.feed.post/1",
              "cid" => "bafy",
              "author" => { "handle" => "alice.bsky.social" },
              "record" => { "text" => "hi", "createdAt" => "2026-05-15T00:00:00.000Z" },
            },
          },
        ],
      }
    end

    def post(nsid, body:)
      @post_calls << [nsid, body]
      { "uri" => "at://did:plc:abc/app.bsky.feed.post/new", "cid" => "bafy" }
    end
  end

  def setup
    @session = FakeSession.new
    @client = FakeXRPCClient.new
    @output = StringIO.new
  end

  def run_with(inputs)
    runner = Tempest::REPL::Runner.new(
      session: @session,
      client: @client,
      input: StubReader.new(inputs),
      output: @output,
    )
    runner.run
    @output.string
  end

  class StubReader
    def initialize(lines)
      @lines = lines.dup
    end

    def readline(_prompt)
      @lines.shift
    end
  end

  def test_quit_command_exits_loop
    out = run_with([":quit"])
    assert_match(/bye/i, out)
  end

  def test_nil_input_treated_as_quit
    out = run_with([nil])
    assert_match(/bye/i, out)
  end

  def test_timeline_command_fetches_and_prints_posts
    out = run_with([":timeline", ":quit"])
    assert_equal 1, @client.timeline_calls
    assert_match(/@alice\.bsky\.social: hi/, out)
  end

  def test_plain_input_creates_post
    out = run_with(["Hello, Bluesky!", ":quit"])
    assert_equal 1, @client.post_calls.length
    nsid, body = @client.post_calls.first
    assert_equal "com.atproto.repo.createRecord", nsid
    assert_equal "did:plc:abc", body[:repo]
    assert_equal "Hello, Bluesky!", body[:record]["text"]
    assert_match(/posted/i, out)
  end

  def test_help_command_lists_available_commands
    out = run_with([":help", ":quit"])
    assert_match(/:timeline/, out)
    assert_match(/:quit/, out)
  end

  def test_unknown_command_prints_message
    out = run_with([":nope", ":quit"])
    assert_match(/unknown.*nope/i, out)
  end

  def test_blank_input_is_ignored
    out_before = @output.string.dup
    out = run_with(["", "   ", ":quit"])
    refute_match(/posted/i, out.sub(out_before, ""))
  end
end
