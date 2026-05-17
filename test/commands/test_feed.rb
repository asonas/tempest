require_relative "../test_helper"
require "stringio"
require "json"
require "tempest/commands/feed"
require "tempest/session"
require "tempest/session_store"
require "tempest/xrpc_client"
require "tempest/cli"

class TestCommandsFeed < Minitest::Test
  class FakeClient
    attr_reader :calls
    def initialize(responses); @responses = responses; @calls = []; end
    def get(nsid, query: nil); @calls << [nsid, query]; @responses.fetch(nsid); end
  end

  def fake_session
    Tempest::Session.new(
      access_jwt: "a", refresh_jwt: "r",
      did: "did:plc:abc", handle: "asonas.bsky.social",
      pds_host: "https://bsky.social",
    )
  end

  def author_feed_response(items:)
    {
      "feed" => items.map { |i| { "post" => i } },
      "cursor" => nil,
    }
  end

  def base_post(created_at:, text: "hi", uri: "at://x", cid: "bafy")
    {
      "uri" => uri, "cid" => cid,
      "author" => { "did" => "did:plc:abc", "handle" => "alice.bsky.social" },
      "record" => { "$type" => "app.bsky.feed.post", "text" => text, "createdAt" => created_at },
      "indexedAt" => created_at,
    }
  end

  def test_me_calls_getAuthorFeed_with_self_did_and_emits_ndjson_when_format_json
    client = FakeClient.new(
      "app.bsky.feed.getAuthorFeed" => author_feed_response(items: [
        base_post(created_at: "2026-05-17T03:00:00Z"),
        base_post(created_at: "2026-05-17T02:00:00Z", uri: "at://y", cid: "bafy2"),
      ]),
    )
    out = StringIO.new
    status = Tempest::Commands::Feed.call(
      argv: ["me", "--format=json"], session: fake_session, client: client,
      stdout: out, stderr: StringIO.new,
    )
    assert_equal 0, status
    nsid, query = client.calls.first
    assert_equal "app.bsky.feed.getAuthorFeed", nsid
    assert_equal "did:plc:abc", query["actor"]
    assert_equal 50, query["limit"]
    lines = out.string.lines
    assert_equal 2, lines.length
    assert_equal "at://x", JSON.parse(lines.first)["uri"]
  end

  def test_timeline_calls_getTimeline
    client = FakeClient.new(
      "app.bsky.feed.getTimeline" => author_feed_response(items: [
        base_post(created_at: "2026-05-17T01:00:00Z"),
      ]),
    )
    out = StringIO.new
    status = Tempest::Commands::Feed.call(
      argv: ["timeline", "--format=json"], session: fake_session, client: client,
      stdout: out, stderr: StringIO.new,
    )
    assert_equal 0, status
    assert_equal "app.bsky.feed.getTimeline", client.calls.first.first
  end

  def test_limit_over_100_returns_64
    client = FakeClient.new({})
    err = StringIO.new
    status = Tempest::Commands::Feed.call(
      argv: ["me", "--limit=101"], session: fake_session, client: client,
      stdout: StringIO.new, stderr: err,
    )
    assert_equal 64, status
    assert_match(/limit/, err.string)
  end

  def test_since_filters_out_older_posts
    client = FakeClient.new(
      "app.bsky.feed.getAuthorFeed" => author_feed_response(items: [
        base_post(created_at: "2026-05-17T05:00:00Z", uri: "at://new"),
        base_post(created_at: "2026-05-15T05:00:00Z", uri: "at://old"),
      ]),
    )
    out = StringIO.new
    Tempest::Commands::Feed.call(
      argv: ["me", "--format=json", "--since=2026-05-16T00:00:00Z"],
      session: fake_session, client: client,
      stdout: out, stderr: StringIO.new,
    )
    uris = out.string.lines.map { |l| JSON.parse(l)["uri"] }
    assert_equal ["at://new"], uris
  end

  def test_format_line_emits_one_line_per_post
    Tempest::REPL::Formatter.color = false
    client = FakeClient.new(
      "app.bsky.feed.getAuthorFeed" => author_feed_response(items: [
        base_post(created_at: "2026-05-17T01:00:00Z"),
      ]),
    )
    out = StringIO.new
    Tempest::Commands::Feed.call(
      argv: ["me", "--format=line"], session: fake_session, client: client,
      stdout: out, stderr: StringIO.new,
    )
    assert_match(/@alice.bsky.social: hi/, out.string)
  end

  def test_author_resolves_handle_via_get_profile_then_calls_getAuthorFeed
    client = FakeClient.new(
      "app.bsky.actor.getProfile" => { "did" => "did:plc:bob", "handle" => "bob.bsky.social" },
      "app.bsky.feed.getAuthorFeed" => author_feed_response(items: [
        base_post(created_at: "2026-05-17T01:00:00Z"),
      ]),
    )
    out = StringIO.new
    status = Tempest::Commands::Feed.call(
      argv: ["author", "bob.bsky.social", "--format=json"],
      session: fake_session, client: client,
      stdout: out, stderr: StringIO.new,
    )
    assert_equal 0, status
    nsids = client.calls.map(&:first)
    assert_equal ["app.bsky.actor.getProfile", "app.bsky.feed.getAuthorFeed"], nsids
    assert_equal "did:plc:bob", client.calls[1][1]["actor"]
  end

  def test_pagination_follows_cursor_when_since_not_yet_crossed
    page1_items = (1..50).map { |i| base_post(created_at: "2026-05-17T#{format('%02d', i % 24)}:00:00Z", uri: "at://a#{i}", cid: "c#{i}") }
    page2_items = [base_post(created_at: "2026-05-15T01:00:00Z", uri: "at://b1", cid: "cb1")]
    client = Class.new do
      def initialize(p1, p2); @p1 = p1; @p2 = p2; @calls = []; end
      attr_reader :calls
      def get(nsid, query: nil)
        @calls << [nsid, query]
        if query && query["cursor"]
          @p2
        else
          @p1
        end
      end
    end.new(
      { "feed" => page1_items.map { |i| { "post" => i } }, "cursor" => "next-cursor" },
      { "feed" => page2_items.map { |i| { "post" => i } }, "cursor" => nil },
    )

    out = StringIO.new
    Tempest::Commands::Feed.call(
      argv: ["me", "--format=json", "--since=2026-05-14T00:00:00Z", "--limit=50"],
      session: fake_session, client: client,
      stdout: out, stderr: StringIO.new,
    )
    assert_equal 2, client.calls.length
    assert_equal "next-cursor", client.calls[1][1]["cursor"]
  end

  def test_pagination_hard_caps_at_5_pages_and_warns
    page = { "feed" => [{ "post" => base_post(created_at: "2026-05-17T01:00:00Z") }], "cursor" => "more" }
    client = Class.new do
      def initialize(p); @p = p; @calls = []; end
      attr_reader :calls
      def get(_, query: nil); @calls << query; @p; end
    end.new(page)

    err = StringIO.new
    status = Tempest::Commands::Feed.call(
      argv: ["me", "--format=json", "--since=2020-01-01T00:00:00Z"],
      session: fake_session, client: client,
      stdout: StringIO.new, stderr: err,
    )
    assert_equal 0, status
    assert_equal 5, client.calls.length
    assert_match(/truncated/, err.string)
  end

  def test_api_error_propagates_to_exit_code_4_via_dispatcher
    Dir.mktmpdir do |dir|
      path = File.join(dir, "session.json")
      seed = Tempest::Session.new(
        access_jwt: "a", refresh_jwt: "r",
        did: "did:plc:abc", handle: "asonas.bsky.social",
        pds_host: "https://bsky.social",
      )
      Tempest::SessionStore.new(path: path).save(seed, identifier: "asonas.bsky.social")

      stub_request(:post, "https://bsky.social/xrpc/com.atproto.server.refreshSession")
        .with(headers: { "Authorization" => "Bearer r" })
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            accessJwt: "a2",
            refreshJwt: "r2",
            did: "did:plc:abc",
            handle: "asonas.bsky.social",
          }.to_json,
        )

      # Stub the XRPC client so any call raises Tempest::APIError.
      xrpc = Object.new
      def xrpc.get(*); raise Tempest::APIError.new(503, "down"); end
      def xrpc.post(*); raise Tempest::APIError.new(503, "down"); end
      Tempest::XRPCClient.singleton_class.send(:alias_method, :__orig_new, :new)
      Tempest::XRPCClient.define_singleton_method(:new) { |*| xrpc }

      err = StringIO.new
      status = Tempest::CLI.run(
        argv: ["feed", "me", "--format=json"],
        env: { "TEMPEST_SESSION_PATH" => path },
        stdout: StringIO.new, stderr: err,
      )
      assert_equal 4, status
      assert_match(/down/, err.string)
    ensure
      if Tempest::XRPCClient.singleton_class.method_defined?(:__orig_new)
        orig = Tempest::XRPCClient.singleton_class.instance_method(:__orig_new)
        Tempest::XRPCClient.define_singleton_method(:new) { |s| orig.bind(Tempest::XRPCClient).call(s) }
        Tempest::XRPCClient.singleton_class.send(:remove_method, :__orig_new)
      end
    end
  end
end
