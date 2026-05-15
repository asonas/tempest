require_relative "test_helper"
require "tempest/timeline_store"
require "tempest/post"
require "fileutils"
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
end
