require_relative "../test_helper"
require "stringio"
require "tempest/commands/follow"
require "tempest/session"

class TestCommandsFollow < Minitest::Test
  class FakeClient
    attr_reader :post_calls, :get_calls

    def initialize
      @post_calls = []
      @get_calls  = []
    end

    def get(nsid, query: nil)
      @get_calls << [nsid, query]
      { "did" => "did:plc:target123" }
    end

    def post(nsid, body: nil)
      @post_calls << [nsid, body]
      {}
    end
  end

  def fake_session
    Tempest::Session.new(
      access_jwt: "a", refresh_jwt: "r",
      did: "did:plc:me", handle: "kakutani.bsky.social",
      pds_host: "https://bsky.social",
    )
  end

  def test_missing_handle_returns_exit_code_64
    err = StringIO.new
    status = Tempest::Commands::Follow.call(
      argv: [], session: fake_session, client: FakeClient.new,
      stdout: StringIO.new, stderr: err,
    )
    assert_equal 64, status
    assert_match(/usage/, err.string)
  end

  def test_empty_handle_returns_exit_code_64
    err = StringIO.new
    status = Tempest::Commands::Follow.call(
      argv: [""], session: fake_session, client: FakeClient.new,
      stdout: StringIO.new, stderr: err,
    )
    assert_equal 64, status
  end

  def test_at_prefixed_handle_is_stripped_from_output
    client = FakeClient.new
    out = StringIO.new
    status = Tempest::Commands::Follow.call(
      argv: ["@twada.bsky.social"], session: fake_session, client: client,
      stdout: out, stderr: StringIO.new,
    )
    assert_equal 0, status
    assert_equal "Followed @twada.bsky.social\n", out.string
    assert_equal "twada.bsky.social", client.get_calls.first[1]["actor"]
  end

  def test_follow_resolves_handle_and_calls_createRecord
    client = FakeClient.new
    out = StringIO.new
    status = Tempest::Commands::Follow.call(
      argv: ["twada.bsky.social"], session: fake_session, client: client,
      stdout: out, stderr: StringIO.new,
    )

    assert_equal 0, status
    assert_equal "Followed @twada.bsky.social\n", out.string

    # handleのDID解決
    assert_equal 1, client.get_calls.length
    assert_equal "app.bsky.actor.getProfile", client.get_calls.first[0]
    assert_equal "twada.bsky.social", client.get_calls.first[1]["actor"]

    # createRecord の呼び出し
    assert_equal 1, client.post_calls.length
    nsid, body = client.post_calls.first
    assert_equal "com.atproto.repo.createRecord", nsid
    assert_equal "did:plc:me",               body["repo"]
    assert_equal "app.bsky.graph.follow",    body["collection"]
    assert_equal "app.bsky.graph.follow",    body["record"]["$type"]
    assert_equal "did:plc:target123",        body["record"]["subject"]
    assert body["record"]["createdAt"]
  end
end
