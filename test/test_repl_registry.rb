require_relative "test_helper"
require "tempest/post"
require "tempest/jetstream/decoder"
require "tempest/repl/registry"

class TestREPLRegistry < Minitest::Test
  def setup
    @registry = Tempest::REPL::Registry.new
  end

  def make_post(uri)
    Tempest::Post.new(
      uri: uri, cid: "bafy",
      handle: "alice.bsky.social", display_name: nil,
      text: "hello", created_at: nil,
    )
  end

  def make_event(did, rkey)
    Tempest::Jetstream::Event.new(
      kind: :commit, did: did, time_us: 1,
      collection: "app.bsky.feed.post", operation: :create,
      rkey: rkey, cid: "bafye",
      text: "stream hi", created_at: nil,
    )
  end

  def test_first_post_is_assigned_dollar_AA
    assert_equal "$AA", @registry.assign_post(make_post("at://x/1"))
  end

  def test_first_url_is_assigned_dollar_LA
    assert_equal "$LA", @registry.assign_url("https://example.com")
  end

  def test_post_and_url_namespaces_are_independent
    pvar = @registry.assign_post(make_post("at://x/1"))
    uvar = @registry.assign_url("https://example.com")
    assert_equal "$AA", pvar
    assert_equal "$LA", uvar
  end

  def test_assign_post_is_idempotent_per_uri
    post = make_post("at://x/1")
    first = @registry.assign_post(post)
    assert_equal first, @registry.assign_post(post)
  end

  def test_assign_post_uses_at_uri_for_jetstream_event
    event = make_event("did:plc:x", "rkey-1")
    var = @registry.assign_post(event)
    assert_equal event, @registry.find_post(var)
  end

  def test_assign_post_idempotent_per_event_at_uri
    e1 = make_event("did:plc:x", "rkey-1")
    e2 = make_event("did:plc:x", "rkey-1")
    assert_equal @registry.assign_post(e1), @registry.assign_post(e2)
  end

  def test_find_post_returns_the_assigned_post
    post = make_post("at://x/1")
    var = @registry.assign_post(post)
    assert_equal post, @registry.find_post(var)
  end

  def test_find_url_returns_the_assigned_url
    var = @registry.assign_url("https://example.com")
    assert_equal "https://example.com", @registry.find_url(var)
  end

  def test_find_post_returns_nil_for_unknown_var
    assert_nil @registry.find_post("$ZZ")
  end

  def test_find_url_returns_nil_for_unknown_var
    assert_nil @registry.find_url("$LZ")
  end

  def test_assign_url_is_idempotent_per_url
    first = @registry.assign_url("https://example.com")
    assert_equal first, @registry.assign_url("https://example.com")
  end

  def test_recycled_url_slot_returns_new_tenant
    26.times { |i| @registry.assign_url("https://example.com/#{i}") }
    var = @registry.assign_url("https://example.com/new")
    assert_equal "$LA", var
    assert_equal "https://example.com/new", @registry.find_url(var)
  end
end
