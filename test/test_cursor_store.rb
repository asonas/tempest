require_relative "test_helper"
require "tempest/cursor_store"
require "fileutils"
require "json"
require "tmpdir"

class TestCursorStore < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir
    @path = File.join(@tmp, "nested", "cursor.json")
  end

  def teardown
    FileUtils.remove_entry(@tmp) if File.exist?(@tmp)
  end

  def test_save_and_load_round_trip
    store = Tempest::CursorStore.new(path: @path)
    saved_at = Time.utc(2026, 5, 15, 9, 30, 0)

    store.save(time_us: 1_725_519_626_134_432, at: saved_at)
    loaded = store.load

    assert_equal 1_725_519_626_134_432, loaded[:time_us]
    assert_equal saved_at, loaded[:saved_at]
  end

  def test_load_returns_nil_when_file_missing
    store = Tempest::CursorStore.new(path: @path)
    assert_nil store.load
  end

  def test_load_returns_nil_for_corrupt_json
    FileUtils.mkdir_p(File.dirname(@path))
    File.write(@path, "not json")

    store = Tempest::CursorStore.new(path: @path)
    assert_nil store.load
  end

  def test_default_path_respects_xdg_config_home
    env = { "XDG_CONFIG_HOME" => "/tmp/xdg" }
    assert_equal "/tmp/xdg/tempest/cursor.json", Tempest::CursorStore.default_path(env)
  end

  def test_default_path_falls_back_to_home_config
    env = { "HOME" => "/Users/test", "XDG_CONFIG_HOME" => "" }
    assert_equal "/Users/test/.config/tempest/cursor.json", Tempest::CursorStore.default_path(env)
  end

  def test_default_path_honors_tempest_cursor_path_override
    env = { "TEMPEST_CURSOR_PATH" => "/custom/cursor.json" }
    assert_equal "/custom/cursor.json", Tempest::CursorStore.default_path(env)
  end
end
