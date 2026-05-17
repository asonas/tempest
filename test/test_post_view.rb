require_relative "test_helper"
require "json"
require "tempest/post_view"

class TestPostView < Minitest::Test
  FIXTURE_DIR = File.expand_path("fixtures/feed_view", __dir__)

  def load_fixture(name)
    JSON.parse(File.read(File.join(FIXTURE_DIR, name)))
  end

  def test_minimal_fixture_produces_full_schema_with_nil_optional_fields
    view = Tempest::PostView.from_feed_view(load_fixture("minimal.json"))
    assert_equal "at://did:plc:abc/app.bsky.feed.post/k1", view[:uri]
    assert_equal "bafyminimal", view[:cid]
    assert_equal({ did: "did:plc:abc", handle: "alice.bsky.social", display_name: "Alice" }, view[:author])
    assert_equal "hello", view[:text]
    assert_equal "2026-05-17T01:00:00.000Z", view[:created_at]
    assert_equal "2026-05-17T01:00:01.500Z", view[:indexed_at]
    assert_equal ["ja"], view[:langs]
    assert_nil view[:reply]
    assert_equal [], view[:facets]
    assert_nil view[:embed][:kind]
    assert_equal 0, view[:like_count]
  end

  def test_with_facets_emits_link_facet_objects
    view = Tempest::PostView.from_feed_view(load_fixture("with_facets.json"))
    assert_equal 1, view[:facets].length
    f = view[:facets].first
    assert_equal :link, f[:kind]
    assert_equal "https://example.com", f[:uri]
    assert_equal 4, f[:byte_start]
    assert_equal 23, f[:byte_end]
    assert_equal 3, view[:like_count]
  end

  def test_reply_fixture_emits_reply_object_with_parent_and_root
    view = Tempest::PostView.from_feed_view(load_fixture("reply.json"))
    assert_equal "at://did:plc:bob/app.bsky.feed.post/par", view[:reply][:parent_uri]
    assert_equal "at://did:plc:bob/app.bsky.feed.post/root", view[:reply][:root_uri]
  end

  def test_embed_kind_strips_the_lexicon_prefix_and_view_suffix
    view = Tempest::PostView.from_feed_view(load_fixture("with_embed_images.json"))
    assert_equal :images, view[:embed][:kind]
  end

  def test_all_top_level_keys_are_always_present
    expected = %i[uri cid author text created_at indexed_at langs reply facets embed like_count repost_count reply_count]
    view = Tempest::PostView.from_feed_view(load_fixture("minimal.json"))
    assert_equal expected.sort, view.keys.sort
  end
end
