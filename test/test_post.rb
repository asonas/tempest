require_relative "test_helper"
require "tempest/post"

class TestPostCreate < Minitest::Test
  class FakeClient
    attr_reader :calls

    def initialize(response = {})
      @response = response
      @calls = []
    end

    def post(nsid, body:)
      @calls << [nsid, body]
      @response
    end
  end

  def test_create_calls_create_record_with_post_record
    client = FakeClient.new(
      "uri" => "at://did:plc:abc/app.bsky.feed.post/xxx",
      "cid" => "bafy",
    )

    response = Tempest::Post.create(
      client,
      did: "did:plc:abc",
      text: "Hello, world!",
      created_at: "2026-05-15T00:00:00.000Z",
    )

    assert_equal 1, client.calls.length
    nsid, body = client.calls.first
    assert_equal "com.atproto.repo.createRecord", nsid
    assert_equal "did:plc:abc", body[:repo]
    assert_equal "app.bsky.feed.post", body[:collection]
    assert_equal "app.bsky.feed.post", body[:record]["$type"]
    assert_equal "Hello, world!", body[:record]["text"]
    assert_equal "2026-05-15T00:00:00.000Z", body[:record]["createdAt"]
    assert_equal "at://did:plc:abc/app.bsky.feed.post/xxx", response["uri"]
  end

  def test_create_defaults_created_at_to_now_in_iso8601_utc
    client = FakeClient.new("uri" => "at://did:plc:abc/app.bsky.feed.post/yyy")

    Tempest::Post.create(client, did: "did:plc:abc", text: "auto")

    _, body = client.calls.first
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/, body[:record]["createdAt"])
  end
end
