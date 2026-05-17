require_relative "../test_helper"
require "stringio"
require "json"
require "tempest/commands/post"
require "tempest/session"

class TestCommandsPost < Minitest::Test
  class FakeXRPCClient
    attr_reader :calls
    def initialize(post_response: nil, get_responses: {})
      @post_response = post_response
      @get_responses = get_responses
      @calls = []
    end
    def post(nsid, body:); @calls << [:post, nsid, body]; @post_response; end
    def get(nsid, query: nil); @calls << [:get, nsid, query]; @get_responses.fetch(nsid); end
  end

  def fake_session
    Tempest::Session.new(
      access_jwt: "a", refresh_jwt: "r",
      did: "did:plc:abc", handle: "asonas.bsky.social",
      pds_host: "https://bsky.social",
    )
  end

  def test_text_argument_creates_a_post_and_prints_human_line
    client = FakeXRPCClient.new(
      post_response: { "uri" => "at://did:plc:abc/app.bsky.feed.post/k", "cid" => "bafy" },
    )
    out = StringIO.new
    status = Tempest::Commands::Post.call(
      argv: ["hello world"], session: fake_session, client: client,
      stdout: out, stderr: StringIO.new, stdin: StringIO.new,
    )
    assert_equal 0, status
    posts = client.calls.select { |c| c.first == :post }
    assert_equal 1, posts.length
    _, nsid, body = posts.first
    assert_equal "com.atproto.repo.createRecord", nsid
    assert_equal "hello world", body[:record]["text"]
    assert_equal ["ja"], body[:record]["langs"]
    assert_match(%r{posted: at://}, out.string)
  end

  def test_json_flag_outputs_uri_and_cid_object
    client = FakeXRPCClient.new(post_response: { "uri" => "at://x", "cid" => "bafy" })
    out = StringIO.new
    Tempest::Commands::Post.call(
      argv: ["--json", "hi"], session: fake_session, client: client,
      stdout: out, stderr: StringIO.new, stdin: StringIO.new,
    )
    payload = JSON.parse(out.string)
    assert_equal "at://x", payload["uri"]
    assert_equal "bafy",   payload["cid"]
  end

  def test_dash_reads_text_from_stdin
    client = FakeXRPCClient.new(post_response: { "uri" => "at://x", "cid" => "bafy" })
    Tempest::Commands::Post.call(
      argv: ["-"], session: fake_session, client: client,
      stdout: StringIO.new, stderr: StringIO.new, stdin: StringIO.new("piped body\n"),
    )
    _, _, body = client.calls.find { |c| c.first == :post }
    assert_equal "piped body", body[:record]["text"]
  end

  def test_empty_text_fails_with_exit_code_64
    client = FakeXRPCClient.new(post_response: { "uri" => "at://x" })
    err = StringIO.new
    status = Tempest::Commands::Post.call(
      argv: ["   "], session: fake_session, client: client,
      stdout: StringIO.new, stderr: err, stdin: StringIO.new,
    )
    assert_equal 64, status
    assert_empty client.calls
    assert_match(/empty/, err.string)
  end

  def test_text_over_300_graphemes_fails_locally
    client = FakeXRPCClient.new(post_response: { "uri" => "at://x" })
    err = StringIO.new
    status = Tempest::Commands::Post.call(
      argv: ["あ" * 301], session: fake_session, client: client,
      stdout: StringIO.new, stderr: err, stdin: StringIO.new,
    )
    assert_equal 64, status
    assert_empty client.calls
    assert_match(/300 graphemes/, err.string)
  end

  def test_reply_to_looks_up_parent_cid_then_creates_post_with_reply_ref
    client = FakeXRPCClient.new(
      post_response: { "uri" => "at://x", "cid" => "bafy" },
      get_responses: {
        "com.atproto.repo.getRecord" => {
          "uri" => "at://did:plc:bob/app.bsky.feed.post/par",
          "cid" => "bafyparent",
        },
      },
    )
    Tempest::Commands::Post.call(
      argv: ["--reply-to", "at://did:plc:bob/app.bsky.feed.post/par", "ack"],
      session: fake_session, client: client,
      stdout: StringIO.new, stderr: StringIO.new, stdin: StringIO.new,
    )
    get_call = client.calls.find { |c| c.first == :get }
    assert_equal "com.atproto.repo.getRecord", get_call[1]
    assert_equal "did:plc:bob", get_call[2]["repo"]
    assert_equal "app.bsky.feed.post", get_call[2]["collection"]
    assert_equal "par", get_call[2]["rkey"]

    _, _, body = client.calls.find { |c| c.first == :post }
    assert_equal "at://did:plc:bob/app.bsky.feed.post/par",
                 body[:record]["reply"]["parent"]["uri"]
    assert_equal "bafyparent", body[:record]["reply"]["parent"]["cid"]
  end
end
