require_relative "test_helper"
require "tempest/account_paths"

class TestAccountPaths < Minitest::Test
  def test_config_base_uses_xdg_config_home_when_set
    base = Tempest::AccountPaths.config_base({ "XDG_CONFIG_HOME" => "/var/cfg" })
    assert_equal "/var/cfg/tempest", base
  end

  def test_config_base_falls_back_to_home_config
    base = Tempest::AccountPaths.config_base({ "HOME" => "/home/asonas" })
    assert_equal "/home/asonas/.config/tempest", base
  end

  def test_legacy_session_path_returns_base_session_json
    path = Tempest::AccountPaths.legacy_session_path({ "HOME" => "/home/asonas" })
    assert_equal "/home/asonas/.config/tempest/session.json", path
  end

  def test_legacy_cursor_path_returns_base_cursor_json
    path = Tempest::AccountPaths.legacy_cursor_path({ "HOME" => "/home/asonas" })
    assert_equal "/home/asonas/.config/tempest/cursor.json", path
  end

  def test_legacy_timeline_path_returns_base_timeline_json
    path = Tempest::AccountPaths.legacy_timeline_path({ "HOME" => "/home/asonas" })
    assert_equal "/home/asonas/.config/tempest/timeline.json", path
  end

  def test_legacy_session_path_honors_tempest_session_path_env
    path = Tempest::AccountPaths.legacy_session_path({ "TEMPEST_SESSION_PATH" => "/tmp/explicit.json" })
    assert_equal "/tmp/explicit.json", path
  end

  def test_legacy_cursor_path_honors_tempest_cursor_path_env
    path = Tempest::AccountPaths.legacy_cursor_path({ "TEMPEST_CURSOR_PATH" => "/tmp/cursor.json" })
    assert_equal "/tmp/cursor.json", path
  end

  def test_legacy_timeline_path_honors_tempest_timeline_path_env
    path = Tempest::AccountPaths.legacy_timeline_path({ "TEMPEST_TIMELINE_PATH" => "/tmp/timeline.json" })
    assert_equal "/tmp/timeline.json", path
  end

  def test_accounts_dir_returns_base_accounts
    path = Tempest::AccountPaths.accounts_dir({ "HOME" => "/home/asonas" })
    assert_equal "/home/asonas/.config/tempest/accounts", path
  end

  def test_account_dir_returns_base_accounts_did
    path = Tempest::AccountPaths.account_dir({ "HOME" => "/home/asonas" }, did: "did:plc:abc")
    assert_equal "/home/asonas/.config/tempest/accounts/did:plc:abc", path
  end

  def test_session_path_returns_account_session_json
    path = Tempest::AccountPaths.session_path({ "HOME" => "/home/asonas" }, did: "did:plc:abc")
    assert_equal "/home/asonas/.config/tempest/accounts/did:plc:abc/session.json", path
  end

  def test_cursor_path_returns_account_cursor_json
    path = Tempest::AccountPaths.cursor_path({ "HOME" => "/home/asonas" }, did: "did:plc:abc")
    assert_equal "/home/asonas/.config/tempest/accounts/did:plc:abc/cursor.json", path
  end

  def test_timeline_path_returns_account_timeline_json
    path = Tempest::AccountPaths.timeline_path({ "HOME" => "/home/asonas" }, did: "did:plc:abc")
    assert_equal "/home/asonas/.config/tempest/accounts/did:plc:abc/timeline.json", path
  end

  def test_accounts_json_path_returns_base_accounts_json
    path = Tempest::AccountPaths.accounts_json_path({ "HOME" => "/home/asonas" })
    assert_equal "/home/asonas/.config/tempest/accounts.json", path
  end

  def test_session_store_default_path_matches_legacy_session_path
    require "tempest/session_store"
    env = { "HOME" => "/home/asonas" }
    assert_equal Tempest::AccountPaths.legacy_session_path(env),
                 Tempest::SessionStore.default_path(env)
  end

  def test_cursor_store_default_path_matches_legacy_cursor_path
    require "tempest/cursor_store"
    env = { "HOME" => "/home/asonas" }
    assert_equal Tempest::AccountPaths.legacy_cursor_path(env),
                 Tempest::CursorStore.default_path(env)
  end

  def test_timeline_store_default_path_matches_legacy_timeline_path
    require "tempest/timeline_store"
    env = { "HOME" => "/home/asonas" }
    assert_equal Tempest::AccountPaths.legacy_timeline_path(env),
                 Tempest::TimelineStore.default_path(env)
  end
end
