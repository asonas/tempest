require_relative "test_helper"
require "tempest/follows"

class TestFollows < Minitest::Test
  class FakeXRPCClient
    attr_reader :calls

    def initialize(pages)
      @pages = pages
      @calls = []
    end

    def get(nsid, query: nil)
      @calls << [nsid, query]
      raise "unexpected nsid #{nsid}" unless nsid == "app.bsky.graph.getFollows"
      @pages.shift || { "follows" => [] }
    end
  end

  def actor
    "did:plc:self"
  end

  def test_fetches_did_and_handle_pairs
    client = FakeXRPCClient.new([
      {
        "follows" => [
          { "did" => "did:plc:a", "handle" => "alice.bsky.social" },
          { "did" => "did:plc:b", "handle" => "bob.bsky.social" },
        ],
      },
    ])

    result = Tempest::Follows.fetch(client, actor: actor)

    assert_equal(
      [
        { did: "did:plc:a", handle: "alice.bsky.social" },
        { did: "did:plc:b", handle: "bob.bsky.social" },
      ],
      result,
    )
    assert_equal "app.bsky.graph.getFollows", client.calls.first.first
    assert_equal actor, client.calls.first.last[:actor]
  end

  def test_paginates_until_cursor_is_absent
    client = FakeXRPCClient.new([
      {
        "follows" => [{ "did" => "did:plc:a", "handle" => "alice.bsky.social" }],
        "cursor" => "page2",
      },
      {
        "follows" => [{ "did" => "did:plc:b", "handle" => "bob.bsky.social" }],
        "cursor" => "page3",
      },
      {
        "follows" => [{ "did" => "did:plc:c", "handle" => "carol.bsky.social" }],
      },
    ])

    result = Tempest::Follows.fetch(client, actor: actor)

    assert_equal 3, result.length
    assert_equal ["did:plc:a", "did:plc:b", "did:plc:c"], result.map { |f| f[:did] }
    assert_equal 3, client.calls.length
    assert_nil client.calls[0].last[:cursor]
    assert_equal "page2", client.calls[1].last[:cursor]
    assert_equal "page3", client.calls[2].last[:cursor]
  end

  def test_returns_empty_array_when_no_follows
    client = FakeXRPCClient.new([{ "follows" => [] }])

    result = Tempest::Follows.fetch(client, actor: actor)

    assert_equal [], result
  end

  def test_handles_missing_follows_key_gracefully
    client = FakeXRPCClient.new([{}])

    result = Tempest::Follows.fetch(client, actor: actor)

    assert_equal [], result
  end
end
