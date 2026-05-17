require_relative "test_helper"
require "tempest/session"
require "tempest/config"
require "base64"
require "json"

class TestSession < Minitest::Test
  def setup
    @config = Tempest::Config.new(
      identifier: "asonas.bsky.social",
      app_password: "xxxx-xxxx-xxxx-xxxx",
      pds_host: "https://bsky.social",
    )
  end

  def fake_jwt(exp:)
    header = Base64.urlsafe_encode64('{"alg":"none"}', padding: false)
    payload = Base64.urlsafe_encode64(JSON.generate({ "exp" => exp }), padding: false)
    "#{header}.#{payload}.sig"
  end

  def test_create_calls_create_session_and_returns_session
    access_jwt = fake_jwt(exp: Time.now.to_i + 3600)
    refresh_jwt = fake_jwt(exp: Time.now.to_i + 86_400)

    stub_request(:post, "https://bsky.social/xrpc/com.atproto.server.createSession")
      .with(
        body: { identifier: "asonas.bsky.social", password: "xxxx-xxxx-xxxx-xxxx" }.to_json,
        headers: { "Content-Type" => "application/json" },
      )
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          accessJwt: access_jwt,
          refreshJwt: refresh_jwt,
          did: "did:plc:abcdef",
          handle: "asonas.bsky.social",
        }.to_json,
      )

    session = Tempest::Session.create(@config)

    assert_equal access_jwt, session.access_jwt
    assert_equal refresh_jwt, session.refresh_jwt
    assert_equal "did:plc:abcdef", session.did
    assert_equal "asonas.bsky.social", session.handle
  end

  def test_create_raises_authentication_error_on_401
    stub_request(:post, "https://bsky.social/xrpc/com.atproto.server.createSession")
      .to_return(
        status: 401,
        headers: { "Content-Type" => "application/json" },
        body: { error: "AuthenticationRequired", message: "Invalid identifier or password" }.to_json,
      )

    assert_raises(Tempest::AuthenticationError) { Tempest::Session.create(@config) }
  end

  def test_create_exposes_error_code_for_auth_factor_token_required
    stub_request(:post, "https://bsky.social/xrpc/com.atproto.server.createSession")
      .to_return(
        status: 401,
        headers: { "Content-Type" => "application/json" },
        body: { error: "AuthFactorTokenRequired", message: "A sign in code has been sent to your email address" }.to_json,
      )

    error = assert_raises(Tempest::AuthenticationError) { Tempest::Session.create(@config) }
    assert_equal "AuthFactorTokenRequired", error.code
  end

  def test_create_passes_auth_factor_token_when_given
    access_jwt = fake_jwt(exp: Time.now.to_i + 3600)
    refresh_jwt = fake_jwt(exp: Time.now.to_i + 86_400)

    stub_request(:post, "https://bsky.social/xrpc/com.atproto.server.createSession")
      .with(
        body: {
          identifier: "asonas.bsky.social",
          password: "xxxx-xxxx-xxxx-xxxx",
          authFactorToken: "ABCDE",
        }.to_json,
      )
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          accessJwt: access_jwt,
          refreshJwt: refresh_jwt,
          did: "did:plc:abcdef",
          handle: "asonas.bsky.social",
        }.to_json,
      )

    session = Tempest::Session.create(@config, auth_factor_token: "ABCDE")
    assert_equal access_jwt, session.access_jwt
  end

  def test_access_expired_returns_true_when_exp_in_past
    session = Tempest::Session.new(
      access_jwt: fake_jwt(exp: Time.now.to_i - 60),
      refresh_jwt: fake_jwt(exp: Time.now.to_i + 86_400),
      did: "did:plc:abcdef",
      handle: "asonas.bsky.social",
      pds_host: "https://bsky.social",
    )

    assert session.access_expired?
  end

  def test_access_expired_returns_false_when_exp_in_future
    session = Tempest::Session.new(
      access_jwt: fake_jwt(exp: Time.now.to_i + 600),
      refresh_jwt: fake_jwt(exp: Time.now.to_i + 86_400),
      did: "did:plc:abcdef",
      handle: "asonas.bsky.social",
      pds_host: "https://bsky.social",
    )

    refute session.access_expired?
  end

  def test_on_change_fires_after_refresh
    old_refresh = fake_jwt(exp: Time.now.to_i + 86_400)
    new_access = fake_jwt(exp: Time.now.to_i + 3600)
    new_refresh = fake_jwt(exp: Time.now.to_i + 172_800)

    session = Tempest::Session.new(
      access_jwt: fake_jwt(exp: Time.now.to_i - 60),
      refresh_jwt: old_refresh,
      did: "did:plc:abcdef",
      handle: "asonas.bsky.social",
      pds_host: "https://bsky.social",
    )

    received = nil
    session.on_change = ->(s) { received = s }

    stub_request(:post, "https://bsky.social/xrpc/com.atproto.server.refreshSession")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          accessJwt: new_access,
          refreshJwt: new_refresh,
          did: "did:plc:abcdef",
          handle: "asonas.bsky.social",
        }.to_json,
      )

    session.refresh!

    assert_same session, received
    assert_equal new_refresh, received.refresh_jwt
  end

  def test_replace_with_copies_credentials_and_fires_on_change
    session = Tempest::Session.new(
      access_jwt: fake_jwt(exp: Time.now.to_i - 60),
      refresh_jwt: fake_jwt(exp: Time.now.to_i - 30),
      did: "did:plc:abcdef",
      handle: "asonas.bsky.social",
      pds_host: "https://bsky.social",
    )

    received = nil
    session.on_change = ->(s) { received = s }

    new_session = Tempest::Session.new(
      access_jwt: fake_jwt(exp: Time.now.to_i + 3600),
      refresh_jwt: fake_jwt(exp: Time.now.to_i + 86_400),
      did: "did:plc:abcdef",
      handle: "asonas.bsky.social",
      pds_host: "https://bsky.social",
    )

    session.replace_with!(new_session)

    assert_equal new_session.access_jwt, session.access_jwt
    assert_equal new_session.refresh_jwt, session.refresh_jwt
    assert_same session, received
  end

  def test_refresh_skips_when_if_unchanged_from_no_longer_matches
    new_access = fake_jwt(exp: Time.now.to_i + 3600)
    session = Tempest::Session.new(
      access_jwt: new_access,
      refresh_jwt: fake_jwt(exp: Time.now.to_i + 86_400),
      did: "did:plc:abcdef",
      handle: "asonas.bsky.social",
      pds_host: "https://bsky.social",
    )

    stale_jwt = fake_jwt(exp: Time.now.to_i - 60)

    session.refresh!(if_unchanged_from: stale_jwt)

    assert_not_requested :post, "https://bsky.social/xrpc/com.atproto.server.refreshSession"
    assert_equal new_access, session.access_jwt
  end

  def test_refresh_serializes_concurrent_callers_into_single_http_call
    old_refresh = fake_jwt(exp: Time.now.to_i + 86_400)
    old_access = fake_jwt(exp: Time.now.to_i - 60)
    new_access = fake_jwt(exp: Time.now.to_i + 3600)
    new_refresh = fake_jwt(exp: Time.now.to_i + 172_800)

    session = Tempest::Session.new(
      access_jwt: old_access,
      refresh_jwt: old_refresh,
      did: "did:plc:abcdef",
      handle: "asonas.bsky.social",
      pds_host: "https://bsky.social",
    )

    started = Queue.new
    release = Queue.new

    stub_request(:post, "https://bsky.social/xrpc/com.atproto.server.refreshSession")
      .to_return do
        started << :go
        release.pop
        {
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            accessJwt: new_access,
            refreshJwt: new_refresh,
            did: "did:plc:abcdef",
            handle: "asonas.bsky.social",
          }.to_json,
        }
      end

    t1 = Thread.new { session.refresh!(if_unchanged_from: old_access) }
    started.pop
    t2 = Thread.new { session.refresh!(if_unchanged_from: old_access) }

    sleep 0.05
    release << :go

    t1.join
    t2.join

    assert_requested :post, "https://bsky.social/xrpc/com.atproto.server.refreshSession", times: 1
    assert_equal new_access, session.access_jwt
  end

  def test_refresh_replaces_tokens
    old_refresh = fake_jwt(exp: Time.now.to_i + 86_400)
    new_access = fake_jwt(exp: Time.now.to_i + 3600)
    new_refresh = fake_jwt(exp: Time.now.to_i + 172_800)

    session = Tempest::Session.new(
      access_jwt: fake_jwt(exp: Time.now.to_i - 60),
      refresh_jwt: old_refresh,
      did: "did:plc:abcdef",
      handle: "asonas.bsky.social",
      pds_host: "https://bsky.social",
    )

    stub_request(:post, "https://bsky.social/xrpc/com.atproto.server.refreshSession")
      .with(headers: { "Authorization" => "Bearer #{old_refresh}" })
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          accessJwt: new_access,
          refreshJwt: new_refresh,
          did: "did:plc:abcdef",
          handle: "asonas.bsky.social",
        }.to_json,
      )

    session.refresh!

    assert_equal new_access, session.access_jwt
    assert_equal new_refresh, session.refresh_jwt
  end
end
