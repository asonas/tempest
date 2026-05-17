require_relative "test_helper"
require "tempest/xrpc_client"
require "tempest/session"
require "base64"
require "json"

class TestXRPCClient < Minitest::Test
  def fake_jwt(exp:)
    header = Base64.urlsafe_encode64('{"alg":"none"}', padding: false)
    payload = Base64.urlsafe_encode64(JSON.generate({ "exp" => exp }), padding: false)
    "#{header}.#{payload}.sig"
  end

  def build_session(access_exp: Time.now.to_i + 3600)
    Tempest::Session.new(
      access_jwt: fake_jwt(exp: access_exp),
      refresh_jwt: fake_jwt(exp: Time.now.to_i + 86_400),
      did: "did:plc:abc",
      handle: "asonas.bsky.social",
      pds_host: "https://bsky.social",
    )
  end

  def test_get_attaches_bearer_token
    session = build_session
    stub_request(:get, "https://bsky.social/xrpc/app.bsky.feed.getTimeline?limit=5")
      .with(headers: { "Authorization" => "Bearer #{session.access_jwt}" })
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { feed: [] }.to_json)

    client = Tempest::XRPCClient.new(session)
    response = client.get("app.bsky.feed.getTimeline", query: { "limit" => 5 })

    assert_equal({ "feed" => [] }, response)
  end

  def test_get_refreshes_session_and_retries_once_on_401
    session = build_session
    old_access = session.access_jwt
    new_access = fake_jwt(exp: Time.now.to_i + 7200)
    new_refresh = fake_jwt(exp: Time.now.to_i + 172_800)

    stub_request(:get, "https://bsky.social/xrpc/app.bsky.feed.getTimeline")
      .with(headers: { "Authorization" => "Bearer #{old_access}" })
      .to_return(status: 401, headers: { "Content-Type" => "application/json" }, body: { error: "ExpiredToken" }.to_json)

    stub_request(:post, "https://bsky.social/xrpc/com.atproto.server.refreshSession")
      .with(headers: { "Authorization" => "Bearer #{session.refresh_jwt}" })
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          accessJwt: new_access,
          refreshJwt: new_refresh,
          did: "did:plc:abc",
          handle: "asonas.bsky.social",
        }.to_json,
      )

    stub_request(:get, "https://bsky.social/xrpc/app.bsky.feed.getTimeline")
      .with(headers: { "Authorization" => "Bearer #{new_access}" })
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { feed: [{ "post" => "x" }] }.to_json)

    client = Tempest::XRPCClient.new(session)
    response = client.get("app.bsky.feed.getTimeline")

    assert_equal({ "feed" => [{ "post" => "x" }] }, response)
    assert_equal new_access, session.access_jwt
  end

  def test_post_refreshes_session_and_retries_once_on_400_expired_token
    session = build_session
    old_access = session.access_jwt
    new_access = fake_jwt(exp: Time.now.to_i + 7200)
    new_refresh = fake_jwt(exp: Time.now.to_i + 172_800)

    body = { repo: "did:plc:abc", collection: "app.bsky.feed.post", record: { text: "hello" } }

    stub_request(:post, "https://bsky.social/xrpc/com.atproto.repo.createRecord")
      .with(
        headers: {
          "Authorization" => "Bearer #{old_access}",
          "Content-Type" => "application/json",
        },
        body: body.to_json,
      )
      .to_return(
        status: 400,
        headers: { "Content-Type" => "application/json" },
        body: { error: "ExpiredToken", message: "Token has expired" }.to_json,
      )

    stub_request(:post, "https://bsky.social/xrpc/com.atproto.server.refreshSession")
      .with(headers: { "Authorization" => "Bearer #{session.refresh_jwt}" })
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          accessJwt: new_access,
          refreshJwt: new_refresh,
          did: "did:plc:abc",
          handle: "asonas.bsky.social",
        }.to_json,
      )

    stub_request(:post, "https://bsky.social/xrpc/com.atproto.repo.createRecord")
      .with(
        headers: {
          "Authorization" => "Bearer #{new_access}",
          "Content-Type" => "application/json",
        },
        body: body.to_json,
      )
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { uri: "at://did:plc:abc/app.bsky.feed.post/abc123", cid: "bafyabc" }.to_json,
      )

    client = Tempest::XRPCClient.new(session)
    response = client.post("com.atproto.repo.createRecord", body: body)

    assert_requested :post, "https://bsky.social/xrpc/com.atproto.server.refreshSession", times: 1
    assert_equal "at://did:plc:abc/app.bsky.feed.post/abc123", response["uri"]
    assert_equal new_access, session.access_jwt
  end

  def test_get_raises_api_error_on_non_auth_failure
    session = build_session
    stub_request(:get, "https://bsky.social/xrpc/app.bsky.feed.getTimeline")
      .to_return(status: 500, headers: { "Content-Type" => "application/json" }, body: { error: "InternalError" }.to_json)

    client = Tempest::XRPCClient.new(session)

    assert_raises(Tempest::APIError) { client.get("app.bsky.feed.getTimeline") }
  end

  def test_post_sends_body_with_bearer_token
    session = build_session
    stub_request(:post, "https://bsky.social/xrpc/com.atproto.repo.createRecord")
      .with(
        headers: {
          "Authorization" => "Bearer #{session.access_jwt}",
          "Content-Type" => "application/json",
        },
        body: { repo: "did:plc:abc", collection: "app.bsky.feed.post", record: { text: "hello" } }.to_json,
      )
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { uri: "at://did:plc:abc/app.bsky.feed.post/abc123", cid: "bafyabc" }.to_json,
      )

    client = Tempest::XRPCClient.new(session)
    response = client.post(
      "com.atproto.repo.createRecord",
      body: { repo: "did:plc:abc", collection: "app.bsky.feed.post", record: { text: "hello" } },
    )

    assert_equal "at://did:plc:abc/app.bsky.feed.post/abc123", response["uri"]
  end
end
