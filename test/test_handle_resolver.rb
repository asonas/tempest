require_relative "test_helper"
require "tempest/handle_resolver"

class TestHandleResolver < Minitest::Test
  class FakeClient
    attr_reader :calls

    def initialize(responses)
      @responses = responses
      @calls = []
    end

    def get(nsid, query: nil)
      @calls << [nsid, query]
      key = query["actor"]
      response = @responses[key]
      raise Tempest::APIError.new(404, { "error" => "NotFound" }) if response.nil?
      response
    end
  end

  def test_resolve_returns_handle_for_known_did
    client = FakeClient.new(
      "did:plc:abc" => { "did" => "did:plc:abc", "handle" => "alice.bsky.social" },
    )
    resolver = Tempest::HandleResolver.new(client: client)

    assert_equal "alice.bsky.social", resolver.resolve("did:plc:abc")
  end

  def test_resolve_caches_repeated_lookups
    client = FakeClient.new(
      "did:plc:abc" => { "did" => "did:plc:abc", "handle" => "alice.bsky.social" },
    )
    resolver = Tempest::HandleResolver.new(client: client)

    resolver.resolve("did:plc:abc")
    resolver.resolve("did:plc:abc")
    resolver.resolve("did:plc:abc")

    assert_equal 1, client.calls.length
  end

  def test_resolve_returns_nil_on_lookup_failure_and_caches_negative_result
    client = FakeClient.new({})
    resolver = Tempest::HandleResolver.new(client: client)

    assert_nil resolver.resolve("did:plc:missing")
    assert_nil resolver.resolve("did:plc:missing")
    assert_equal 1, client.calls.length
  end

  def test_resolve_uses_app_bsky_actor_get_profile
    client = FakeClient.new(
      "did:plc:abc" => { "did" => "did:plc:abc", "handle" => "alice.bsky.social" },
    )
    resolver = Tempest::HandleResolver.new(client: client)
    resolver.resolve("did:plc:abc")

    nsid, query = client.calls.first
    assert_equal "app.bsky.actor.getProfile", nsid
    assert_equal({ "actor" => "did:plc:abc" }, query)
  end

  def test_seed_pre_populates_cache_without_xrpc_call
    client = FakeClient.new({})
    resolver = Tempest::HandleResolver.new(client: client)
    resolver.seed("did:plc:abc", "alice.bsky.social")

    assert_equal "alice.bsky.social", resolver.resolve("did:plc:abc")
    assert_empty client.calls
  end
end
