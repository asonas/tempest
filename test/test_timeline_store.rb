require_relative "test_helper"
require "tempest/timeline_store"
require "tempest/post"
require "tempest/facet"
require "fileutils"
require "json"
require "tmpdir"

class TestTimelineStore < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir
    @path = File.join(@tmp, "nested", "timeline.json")
  end

  def teardown
    FileUtils.remove_entry(@tmp) if File.exist?(@tmp)
  end

  def test_save_and_load_round_trip
    store = Tempest::TimelineStore.new(path: @path)
    posts = [
      Tempest::Post.new(
        uri: "at://did:plc:a/app.bsky.feed.post/1",
        cid: "bafy1",
        handle: "alice.example",
        display_name: "Alice",
        text: "hello",
        created_at: "2026-05-15T09:00:00.000Z",
      ),
      Tempest::Post.new(
        uri: "at://did:plc:b/app.bsky.feed.post/2",
        cid: "bafy2",
        handle: "bob.example",
        display_name: nil,
        text: "world",
        created_at: "2026-05-15T09:05:00.000Z",
      ),
    ]
    saved_at = Time.utc(2026, 5, 15, 9, 30, 0)

    store.save(posts: posts, at: saved_at)
    loaded = store.load

    assert_equal saved_at, loaded[:saved_at]
    assert_equal posts, loaded[:posts]
  end

  def test_save_and_load_preserves_reply_parent_uri
    store = Tempest::TimelineStore.new(path: @path)
    posts = [
      Tempest::Post.new(
        uri: "at://did:plc:replier/app.bsky.feed.post/rk",
        cid: "bafy",
        handle: "alice.example",
        display_name: nil,
        text: "thanks",
        created_at: "2026-05-15T09:00:00.000Z",
        reply_parent_uri: "at://did:plc:parent/app.bsky.feed.post/pk",
      ),
    ]

    store.save(posts: posts, at: Time.utc(2026, 5, 15))
    loaded = store.load
    assert_equal "at://did:plc:parent/app.bsky.feed.post/pk", loaded[:posts].first.reply_parent_uri
  end

  def test_load_returns_nil_when_file_missing
    store = Tempest::TimelineStore.new(path: @path)
    assert_nil store.load
  end

  def test_load_returns_nil_for_corrupt_json
    FileUtils.mkdir_p(File.dirname(@path))
    File.write(@path, "not json")

    store = Tempest::TimelineStore.new(path: @path)
    assert_nil store.load
  end

  def test_default_path_respects_xdg_config_home
    env = { "XDG_CONFIG_HOME" => "/tmp/xdg" }
    assert_equal "/tmp/xdg/tempest/timeline.json", Tempest::TimelineStore.default_path(env)
  end

  def test_default_path_falls_back_to_home_config
    env = { "HOME" => "/Users/test", "XDG_CONFIG_HOME" => "" }
    assert_equal "/Users/test/.config/tempest/timeline.json", Tempest::TimelineStore.default_path(env)
  end

  def test_default_path_honors_tempest_timeline_path_override
    env = { "TEMPEST_TIMELINE_PATH" => "/custom/timeline.json" }
    assert_equal "/custom/timeline.json", Tempest::TimelineStore.default_path(env)
  end

  def test_save_and_load_preserves_link_facets
    store = Tempest::TimelineStore.new(path: @path)
    facet = Tempest::Facet::Link.new(
      byte_start: 6, byte_end: 25, uri: "https://example.com/long/path",
    )
    post = Tempest::Post.new(
      uri: "at://x", cid: "bafy",
      handle: "a", display_name: nil, text: "hello example.com/lo...",
      created_at: "2026-05-15T09:00:00.000Z",
      facets: [facet],
    )

    store.save(posts: [post])
    loaded = store.load

    assert_equal [facet], loaded[:posts].first.facets
  end

  def test_load_tolerates_old_snapshots_without_facets
    FileUtils.mkdir_p(File.dirname(@path))
    payload = {
      "posts" => [
        {
          "uri" => "at://x", "cid" => "bafy",
          "handle" => "a", "display_name" => nil,
          "text" => "old", "created_at" => "2026-05-15T09:00:00.000Z",
        },
      ],
      "saved_at" => "2026-05-15T09:30:00.000000Z",
    }
    File.write(@path, JSON.generate(payload))

    store = Tempest::TimelineStore.new(path: @path)
    loaded = store.load

    refute_nil loaded
    assert_equal [], loaded[:posts].first.facets
  end

  def test_save_trims_to_most_recent_fifty_posts
    store = Tempest::TimelineStore.new(path: @path)
    posts = (1..60).map do |i|
      Tempest::Post.new(
        uri: "at://did:plc:a/app.bsky.feed.post/#{i}",
        cid: "bafy#{i}",
        handle: "alice.example",
        display_name: "Alice",
        text: "post ##{i}",
        created_at: "2026-05-15T09:00:00.000Z",
      )
    end

    store.save(posts: posts)
    loaded = store.load

    assert_equal 50, loaded[:posts].length
    assert_equal "at://did:plc:a/app.bsky.feed.post/11", loaded[:posts].first.uri
    assert_equal "at://did:plc:a/app.bsky.feed.post/60", loaded[:posts].last.uri
  end
end
