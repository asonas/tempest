require_relative "test_helper"
require "tempest/session_store"
require "tempest/session"
require "fileutils"
require "json"
require "tmpdir"

class TestSessionStore < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir
    @path = File.join(@tmp, "nested", "session.json")
  end

  def teardown
    FileUtils.remove_entry(@tmp) if File.exist?(@tmp)
  end

  def build_session
    Tempest::Session.new(
      access_jwt: "access",
      refresh_jwt: "refresh",
      did: "did:plc:abcdef",
      handle: "asonas.bsky.social",
      pds_host: "https://bsky.social",
    )
  end

  def test_save_writes_session_data_with_restrictive_permissions
    store = Tempest::SessionStore.new(path: @path)
    store.save(build_session, identifier: "asonas.bsky.social")

    data = JSON.parse(File.read(@path))
    assert_equal "refresh", data["refresh_jwt"]
    assert_equal "access", data["access_jwt"]
    assert_equal "did:plc:abcdef", data["did"]
    assert_equal "asonas.bsky.social", data["handle"]
    assert_equal "asonas.bsky.social", data["identifier"]
    assert_equal "https://bsky.social", data["pds_host"]

    mode = File.stat(@path).mode & 0o777
    assert_equal 0o600, mode
  end

  def test_save_creates_missing_parent_directory
    store = Tempest::SessionStore.new(path: @path)
    store.save(build_session, identifier: "asonas.bsky.social")
    assert File.exist?(@path)
  end

  def test_load_returns_session_when_identifier_and_host_match
    store = Tempest::SessionStore.new(path: @path)
    store.save(build_session, identifier: "asonas.bsky.social")

    loaded = store.load(identifier: "asonas.bsky.social", pds_host: "https://bsky.social")
    refute_nil loaded
    assert_equal "refresh", loaded.refresh_jwt
    assert_equal "access", loaded.access_jwt
    assert_equal "did:plc:abcdef", loaded.did
    assert_equal "asonas.bsky.social", loaded.handle
    assert_equal "https://bsky.social", loaded.pds_host
  end

  def test_load_returns_nil_when_file_missing
    store = Tempest::SessionStore.new(path: @path)
    assert_nil store.load(identifier: "asonas.bsky.social", pds_host: "https://bsky.social")
  end

  def test_load_returns_nil_when_identifier_differs
    store = Tempest::SessionStore.new(path: @path)
    store.save(build_session, identifier: "asonas.bsky.social")
    assert_nil store.load(identifier: "other.bsky.social", pds_host: "https://bsky.social")
  end

  def test_load_returns_nil_when_pds_host_differs
    store = Tempest::SessionStore.new(path: @path)
    store.save(build_session, identifier: "asonas.bsky.social")
    assert_nil store.load(identifier: "asonas.bsky.social", pds_host: "https://other.example")
  end

  def test_load_returns_session_when_identifier_filter_is_nil
    store = Tempest::SessionStore.new(path: @path)
    store.save(build_session, identifier: "asonas.bsky.social")

    loaded = store.load(identifier: nil, pds_host: nil)
    refute_nil loaded
    assert_equal "asonas.bsky.social", loaded.handle
  end

  def test_load_exposes_saved_identifier_on_loaded_session
    store = Tempest::SessionStore.new(path: @path)
    store.save(build_session, identifier: "asonas.bsky.social")

    loaded = store.load(identifier: nil, pds_host: nil)
    assert_equal "asonas.bsky.social", loaded.identifier
  end

  def test_load_returns_nil_on_malformed_json
    FileUtils.mkdir_p(File.dirname(@path))
    File.write(@path, "{not-json")
    store = Tempest::SessionStore.new(path: @path)
    assert_nil store.load(identifier: "asonas.bsky.social", pds_host: "https://bsky.social")
  end

  def test_clear_removes_file
    store = Tempest::SessionStore.new(path: @path)
    store.save(build_session, identifier: "asonas.bsky.social")
    store.clear
    refute File.exist?(@path)
  end

  def test_clear_when_file_missing_is_noop
    store = Tempest::SessionStore.new(path: @path)
    store.clear
  end

  def test_default_path_uses_tempest_session_path_when_set
    path = Tempest::SessionStore.default_path({ "TEMPEST_SESSION_PATH" => "/tmp/explicit.json" })
    assert_equal "/tmp/explicit.json", path
  end

  def test_default_path_uses_xdg_config_home_when_set
    path = Tempest::SessionStore.default_path({ "XDG_CONFIG_HOME" => "/var/cfg" })
    assert_equal "/var/cfg/tempest/session.json", path
  end

  def test_default_path_falls_back_to_home_config
    path = Tempest::SessionStore.default_path({ "HOME" => "/home/asonas" })
    assert_equal "/home/asonas/.config/tempest/session.json", path
  end

  def test_for_uses_per_did_path
    store = Tempest::SessionStore.for({ "XDG_CONFIG_HOME" => @tmp }, did: "did:plc:abc")
    assert_equal File.join(@tmp, "tempest", "accounts", "did:plc:abc", "session.json"), store.path
  end

  def test_for_save_and_load_round_trips_through_per_did_path
    env = { "XDG_CONFIG_HOME" => @tmp }
    did = "did:plc:abc"
    store = Tempest::SessionStore.for(env, did: did)
    store.save(build_session, identifier: "asonas.bsky.social")

    expected = File.join(@tmp, "tempest", "accounts", did, "session.json")
    assert File.exist?(expected)

    loaded = Tempest::SessionStore.for(env, did: did).load(identifier: nil, pds_host: nil)
    refute_nil loaded
    assert_equal "did:plc:abcdef", loaded.did
  end
end
