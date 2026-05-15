require_relative "test_helper"
require "tempest/timeline"

class TestTimeline < Minitest::Test
  class FakeClient
    attr_reader :last_call

    def initialize(response)
      @response = response
    end

    def get(nsid, query: nil)
      @last_call = [nsid, query]
      @response
    end
  end

  def test_fetch_calls_get_timeline_and_maps_to_posts
    response = {
      "feed" => [
        {
          "post" => {
            "uri" => "at://did:plc:a/app.bsky.feed.post/1",
            "cid" => "bafyone",
            "author" => { "handle" => "alice.bsky.social", "displayName" => "Alice" },
            "record" => { "text" => "hello world", "createdAt" => "2026-05-15T01:23:45.000Z" },
          },
        },
        {
          "post" => {
            "uri" => "at://did:plc:b/app.bsky.feed.post/2",
            "cid" => "bafytwo",
            "author" => { "handle" => "bob.bsky.social" },
            "record" => { "text" => "second post", "createdAt" => "2026-05-15T01:25:00.000Z" },
          },
        },
      ],
      "cursor" => "next-cursor",
    }
    client = FakeClient.new(response)

    posts = Tempest::Timeline.fetch(client, limit: 25)

    nsid, query = client.last_call
    assert_equal "app.bsky.feed.getTimeline", nsid
    assert_equal({ "limit" => 25 }, query)

    assert_equal 2, posts.length
    assert_equal "alice.bsky.social", posts[0].handle
    assert_equal "hello world", posts[0].text
    assert_equal "at://did:plc:a/app.bsky.feed.post/1", posts[0].uri
    assert_equal "2026-05-15T01:23:45.000Z", posts[0].created_at
    assert_equal "bob.bsky.social", posts[1].handle
  end

  def test_fetch_defaults_limit
    client = FakeClient.new({ "feed" => [] })

    Tempest::Timeline.fetch(client)

    _, query = client.last_call
    assert_equal({ "limit" => 50 }, query)
  end
end
