require_relative "test_helper"
require "tempest/handle_lookup"

class TestHandleLookup < Minitest::Test
  class FakeClient
    def initialize(response); @response = response; end
    def get(nsid, query: nil); @response; end
  end

  def test_did_input_is_returned_unchanged_without_api_call
    client = FakeClient.new(nil)
    def client.get(*); raise "should not call"; end
    assert_equal "did:plc:abc",
                 Tempest::HandleLookup.resolve("did:plc:abc", client: client)
  end

  def test_handle_input_calls_get_profile_and_returns_did
    client = FakeClient.new("did" => "did:plc:abc", "handle" => "alice.bsky.social")
    assert_equal "did:plc:abc",
                 Tempest::HandleLookup.resolve("alice.bsky.social", client: client)
  end

  def test_at_prefix_stripped
    client = FakeClient.new("did" => "did:plc:abc")
    assert_equal "did:plc:abc",
                 Tempest::HandleLookup.resolve("@alice.bsky.social", client: client)
  end

  def test_unknown_handle_raises_tempest_error
    client = FakeClient.new(nil)
    def client.get(*); raise Tempest::APIError.new(400, "InvalidRequest"); end
    assert_raises(Tempest::APIError) do
      Tempest::HandleLookup.resolve("ghost.bsky.social", client: client)
    end
  end
end
