require_relative "test_helper"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"
require "tempest/cli"
require "tempest/session"
require "tempest/session_store"

class TestCLI < Minitest::Test
  def test_run_prints_error_and_returns_non_zero_when_env_missing
    err = StringIO.new
    status = Tempest::CLI.run(argv: [], env: {}, stdout: StringIO.new, stderr: err)

    assert status != 0
    assert_match(/TEMPEST_IDENTIFIER/, err.string)
  end

  def test_run_prints_version_when_version_flag
    out = StringIO.new
    status = Tempest::CLI.run(argv: ["--version"], env: {}, stdout: out, stderr: StringIO.new)

    assert_equal 0, status
    assert_match(/tempest #{Regexp.escape(Tempest::VERSION)}/, out.string)
  end

  def test_run_passes_auth_factor_token_from_env
    env = {
      "TEMPEST_IDENTIFIER" => "ason.as",
      "TEMPEST_APP_PASSWORD" => "xxxx",
      "TEMPEST_AUTH_FACTOR_TOKEN" => "ABCDE",
    }
    captured = nil
    fake_session_factory = ->(config, auth_factor_token: nil) do
      captured = auth_factor_token
      raise Tempest::AuthenticationError.new("stop here", code: "stub")
    end

    err = StringIO.new
    Tempest::CLI.run(
      argv: [],
      env: env,
      stdout: StringIO.new,
      stderr: err,
      session_factory: fake_session_factory,
    )

    assert_equal "ABCDE", captured
  end

  def test_sign_in_reuses_stored_session_when_refresh_succeeds
    Dir.mktmpdir do |dir|
      store = Tempest::SessionStore.new(path: File.join(dir, "session.json"))
      seed = Tempest::Session.new(
        access_jwt: "old-access",
        refresh_jwt: "old-refresh",
        did: "did:plc:x",
        handle: "asonas.bsky.social",
        pds_host: "https://bsky.social",
      )
      store.save(seed, identifier: "asonas.bsky.social")

      stub_request(:post, "https://bsky.social/xrpc/com.atproto.server.refreshSession")
        .with(headers: { "Authorization" => "Bearer old-refresh" })
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            accessJwt: "new-access",
            refreshJwt: "new-refresh",
            did: "did:plc:x",
            handle: "asonas.bsky.social",
          }.to_json,
        )

      factory_invoked = false
      factory = ->(*_args, **_kwargs) { factory_invoked = true; raise "must not be called" }

      env = {}
      session = Tempest::CLI.sign_in(env, StringIO.new, StringIO.new, factory, store: store)

      refute factory_invoked, "session_factory should be skipped when refresh succeeds"
      assert_equal "new-access", session.access_jwt
      persisted = JSON.parse(File.read(store.path))
      assert_equal "new-refresh", persisted["refresh_jwt"]
    end
  end

  def test_sign_in_skips_config_when_cache_refreshes_with_empty_env
    Dir.mktmpdir do |dir|
      store = Tempest::SessionStore.new(path: File.join(dir, "session.json"))
      seed = Tempest::Session.new(
        access_jwt: "old",
        refresh_jwt: "old-r",
        did: "did:plc:x",
        handle: "asonas.bsky.social",
        pds_host: "https://bsky.social",
      )
      store.save(seed, identifier: "asonas.bsky.social")

      stub_request(:post, "https://bsky.social/xrpc/com.atproto.server.refreshSession")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            accessJwt: "new",
            refreshJwt: "new-r",
            did: "did:plc:x",
            handle: "asonas.bsky.social",
          }.to_json,
        )

      factory = ->(*_args, **_kwargs) { raise "must not be called" }

      session = Tempest::CLI.sign_in({}, StringIO.new, StringIO.new, factory, store: store)

      assert_equal "new", session.access_jwt
      assert_equal "asonas.bsky.social", session.identifier
    end
  end

  def test_sign_in_raises_missing_value_when_no_cache_and_no_credentials
    Dir.mktmpdir do |dir|
      store = Tempest::SessionStore.new(path: File.join(dir, "session.json"))
      factory = ->(*_args, **_kwargs) { raise "must not be called" }

      assert_raises(Tempest::Config::MissingValue) do
        Tempest::CLI.sign_in({}, StringIO.new, StringIO.new, factory, store: store)
      end
    end
  end

  def test_sign_in_falls_back_when_refresh_unauthorized
    Dir.mktmpdir do |dir|
      store = Tempest::SessionStore.new(path: File.join(dir, "session.json"))
      seed = Tempest::Session.new(
        access_jwt: "old-access",
        refresh_jwt: "old-refresh",
        did: "did:plc:x",
        handle: "asonas.bsky.social",
        pds_host: "https://bsky.social",
      )
      store.save(seed, identifier: "asonas.bsky.social")

      stub_request(:post, "https://bsky.social/xrpc/com.atproto.server.refreshSession")
        .to_return(
          status: 401,
          headers: { "Content-Type" => "application/json" },
          body: { error: "ExpiredToken", message: "Token expired" }.to_json,
        )

      fresh = Tempest::Session.new(
        access_jwt: "fresh-access",
        refresh_jwt: "fresh-refresh",
        did: "did:plc:x",
        handle: "asonas.bsky.social",
        pds_host: "https://bsky.social",
      )
      factory = ->(_config, auth_factor_token: nil) { fresh }

      env = {
        "TEMPEST_IDENTIFIER" => "asonas.bsky.social",
        "TEMPEST_APP_PASSWORD" => "xxxx",
      }
      session = Tempest::CLI.sign_in(env, StringIO.new, StringIO.new, factory, store: store)

      assert_equal "fresh-access", session.access_jwt
      persisted = JSON.parse(File.read(store.path))
      assert_equal "fresh-refresh", persisted["refresh_jwt"]
    end
  end

  def test_sign_in_saves_session_after_fresh_create
    Dir.mktmpdir do |dir|
      store = Tempest::SessionStore.new(path: File.join(dir, "session.json"))
      fresh = Tempest::Session.new(
        access_jwt: "a",
        refresh_jwt: "r",
        did: "did:plc:y",
        handle: "asonas.bsky.social",
        pds_host: "https://bsky.social",
      )
      factory = ->(_config, auth_factor_token: nil) { fresh }

      env = {
        "TEMPEST_IDENTIFIER" => "asonas.bsky.social",
        "TEMPEST_APP_PASSWORD" => "xxxx",
      }
      Tempest::CLI.sign_in(env, StringIO.new, StringIO.new, factory, store: store)

      persisted = JSON.parse(File.read(store.path))
      assert_equal "r", persisted["refresh_jwt"]
      assert_equal "asonas.bsky.social", persisted["identifier"]
    end
  end

  def test_feed_mode_defaults_to_home
    assert_equal :home, Tempest::CLI.feed_mode(argv: [], env: {})
  end

  def test_feed_mode_respects_flag_self
    assert_equal :self, Tempest::CLI.feed_mode(argv: ["--feed=self"], env: {})
  end

  def test_feed_mode_respects_flag_home_explicit
    assert_equal :home, Tempest::CLI.feed_mode(argv: ["--feed=home"], env: {})
  end

  def test_feed_mode_respects_env_self
    assert_equal :self, Tempest::CLI.feed_mode(argv: [], env: { "TEMPEST_FEED" => "self" })
  end

  def test_feed_mode_argv_takes_precedence_over_env
    assert_equal :self,
      Tempest::CLI.feed_mode(argv: ["--feed=self"], env: { "TEMPEST_FEED" => "home" })
  end

  class FakeSessionForFeed
    attr_reader :did, :handle
    def initialize
      @did = "did:plc:self"
      @handle = "asonas.bsky.social"
    end
  end

  class FollowsStubClient
    def initialize(follows)
      @follows = follows
      @calls = []
    end

    attr_reader :calls

    def get(nsid, query: nil)
      @calls << [nsid, query]
      raise "unexpected nsid #{nsid}" unless nsid == "app.bsky.graph.getFollows"
      { "follows" => @follows.map { |f| { "did" => f[:did], "handle" => f[:handle] } } }
    end
  end

  def test_build_subscription_self_mode_returns_self_did_only
    session = FakeSessionForFeed.new
    plan = Tempest::CLI.build_subscription(
      mode: :self, session: session, client: FollowsStubClient.new([]),
    )

    assert_equal [session.did], plan.wanted_dids
    assert_nil plan.filter
  end

  def test_build_subscription_home_mode_fetches_follows_and_includes_them
    session = FakeSessionForFeed.new
    follows = [
      { did: "did:plc:a", handle: "alice.bsky.social" },
      { did: "did:plc:b", handle: "bob.bsky.social" },
    ]
    client = FollowsStubClient.new(follows)

    plan = Tempest::CLI.build_subscription(mode: :home, session: session, client: client)

    assert_includes plan.wanted_dids, session.did
    assert_includes plan.wanted_dids, "did:plc:a"
    assert_includes plan.wanted_dids, "did:plc:b"
    assert_equal 1, client.calls.length, "should call getFollows exactly once for a single page"
  end

  def test_build_subscription_home_mode_seeds_handle_resolver
    session = FakeSessionForFeed.new
    follows = [{ did: "did:plc:a", handle: "alice.bsky.social" }]
    client = FollowsStubClient.new(follows)
    resolver = Tempest::HandleResolver.new(client: client)

    Tempest::CLI.build_subscription(
      mode: :home, session: session, client: client, handle_resolver: resolver,
    )

    # If seeding worked, resolve should NOT hit the API again.
    initial_calls = client.calls.length
    assert_equal "alice.bsky.social", resolver.resolve("did:plc:a")
    assert_equal initial_calls, client.calls.length, "seeded handle should not trigger lookup"
  end

  def test_feed_mode_rejects_unknown_value
    assert_raises(ArgumentError) do
      Tempest::CLI.feed_mode(argv: ["--feed=garbage"], env: {})
    end
  end

  def test_cursor_store_honors_env_override
    env = { "TEMPEST_CURSOR_PATH" => "/tmp/test-cursor.json" }
    store = Tempest::CLI.cursor_store(env)
    assert_equal "/tmp/test-cursor.json", store.path
  end

  def test_cursor_store_falls_back_to_xdg_path
    env = { "XDG_CONFIG_HOME" => "/tmp/xdg" }
    store = Tempest::CLI.cursor_store(env)
    assert_equal "/tmp/xdg/tempest/cursor.json", store.path
  end

  def test_timeline_store_honors_env_override
    env = { "TEMPEST_TIMELINE_PATH" => "/tmp/test-timeline.json" }
    store = Tempest::CLI.timeline_store(env)
    assert_equal "/tmp/test-timeline.json", store.path
  end

  def test_timeline_store_falls_back_to_xdg_path
    env = { "XDG_CONFIG_HOME" => "/tmp/xdg" }
    store = Tempest::CLI.timeline_store(env)
    assert_equal "/tmp/xdg/tempest/timeline.json", store.path
  end

  def test_opener_for_env_uses_runner_default_when_no_env_var
    opener = Tempest::CLI.opener_for(env: {})
    assert_equal Tempest::REPL::Runner::DEFAULT_OPENER, opener
  end

  def test_opener_for_env_uses_runner_default_when_env_var_is_empty
    opener = Tempest::CLI.opener_for(env: { "TEMPEST_OPEN_CMD" => "" })
    assert_equal Tempest::REPL::Runner::DEFAULT_OPENER, opener
  end

  def test_opener_for_env_wraps_tempest_open_cmd_and_passes_url
    recorded = nil
    fake_system = ->(*args) { recorded = args; true }
    opener = Tempest::CLI.opener_for(
      env: { "TEMPEST_OPEN_CMD" => "/bin/echo" },
      system_proc: fake_system,
    )
    assert opener.call("https://example.com")
    assert_equal ["/bin/echo", "https://example.com"], recorded
  end

  def test_opener_for_env_wrapped_opener_returns_falsey_on_system_failure
    fake_system = ->(*) { false }
    opener = Tempest::CLI.opener_for(
      env: { "TEMPEST_OPEN_CMD" => "/bin/false" },
      system_proc: fake_system,
    )
    refute opener.call("https://example.com")
  end

  def test_sign_in_persists_tokens_when_session_refreshes_later
    Dir.mktmpdir do |dir|
      store = Tempest::SessionStore.new(path: File.join(dir, "session.json"))
      fresh = Tempest::Session.new(
        access_jwt: "a",
        refresh_jwt: "r",
        did: "did:plc:y",
        handle: "asonas.bsky.social",
        pds_host: "https://bsky.social",
      )
      factory = ->(_config, auth_factor_token: nil) { fresh }

      env = {
        "TEMPEST_IDENTIFIER" => "asonas.bsky.social",
        "TEMPEST_APP_PASSWORD" => "xxxx",
      }
      session = Tempest::CLI.sign_in(env, StringIO.new, StringIO.new, factory, store: store)

      stub_request(:post, "https://bsky.social/xrpc/com.atproto.server.refreshSession")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            accessJwt: "a2",
            refreshJwt: "r2",
            did: "did:plc:y",
            handle: "asonas.bsky.social",
          }.to_json,
        )
      session.refresh!

      persisted = JSON.parse(File.read(store.path))
      assert_equal "r2", persisted["refresh_jwt"]
    end
  end
end
