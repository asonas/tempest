require_relative "test_helper"
require "tempest/accounts_store"
require "fileutils"
require "json"
require "tmpdir"
require "time"

class TestAccountsStore < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir
    @env = { "XDG_CONFIG_HOME" => @tmp }
    @path = File.join(@tmp, "tempest", "accounts.json")
  end

  def teardown
    FileUtils.remove_entry(@tmp) if File.exist?(@tmp)
  end

  def build_store
    Tempest::AccountsStore.new(env: @env)
  end

  def test_returns_empty_state_when_accounts_json_missing
    store = build_store
    assert_nil store.default
    assert_equal [], store.accounts
  end

  def add(store, did:, handle: nil, identifier: nil, pds_host: "https://bsky.social", added_at: Time.now.utc)
    store.add_account(
      did: did,
      handle: handle || "#{did}.handle",
      identifier: identifier || handle || "#{did}.handle",
      pds_host: pds_host,
      added_at: added_at,
    )
  end

  def test_add_account_persists_and_appears_in_accounts
    store = build_store
    added_at = Time.utc(2026, 5, 18, 10, 0, 0)
    add(store, did: "did:plc:a", handle: "asonas.bsky.social", identifier: "asonas.bsky.social", added_at: added_at)

    reloaded = build_store
    assert_equal 1, reloaded.accounts.length
    a = reloaded.accounts.first
    assert_equal "did:plc:a", a.did
    assert_equal "asonas.bsky.social", a.handle
    assert_equal "asonas.bsky.social", a.identifier
    assert_equal "https://bsky.social", a.pds_host
    assert_equal added_at, a.added_at
  end

  def test_first_added_account_becomes_default
    store = build_store
    add(store, did: "did:plc:a")
    assert_equal "did:plc:a", store.default

    add(store, did: "did:plc:b")
    assert_equal "did:plc:a", store.default
  end

  def test_re_adding_same_did_overwrites_fields_but_preserves_added_at
    store = build_store
    first_time = Time.utc(2026, 5, 1, 0, 0, 0)
    add(store, did: "did:plc:a", handle: "old.bsky.social", identifier: "old.bsky.social", added_at: first_time)

    later = Time.utc(2026, 5, 18, 12, 0, 0)
    add(store, did: "did:plc:a", handle: "new.bsky.social", identifier: "new@example.com",
        pds_host: "https://other.example", added_at: later)

    reloaded = build_store
    assert_equal 1, reloaded.accounts.length
    a = reloaded.accounts.first
    assert_equal "new.bsky.social", a.handle
    assert_equal "new@example.com", a.identifier
    assert_equal "https://other.example", a.pds_host
    assert_equal first_time, a.added_at
  end

  def test_set_default_updates_default
    store = build_store
    add(store, did: "did:plc:a", handle: "a.bsky")
    add(store, did: "did:plc:b", handle: "b.bsky")

    store.set_default("did:plc:b")
    assert_equal "did:plc:b", store.default
    assert_equal "did:plc:b", build_store.default
  end

  def test_set_default_accepts_handle
    store = build_store
    add(store, did: "did:plc:a", handle: "a.bsky")
    add(store, did: "did:plc:b", handle: "b.bsky")

    store.set_default("b.bsky")
    assert_equal "did:plc:b", store.default
  end

  def test_set_default_raises_for_unknown_value
    store = build_store
    add(store, did: "did:plc:a")
    assert_raises(ArgumentError) { store.set_default("unknown") }
  end

  def test_resolve_by_did
    store = build_store
    add(store, did: "did:plc:a", handle: "a.bsky")
    assert_equal "did:plc:a", store.resolve("did:plc:a").did
  end

  def test_resolve_by_handle
    store = build_store
    add(store, did: "did:plc:a", handle: "a.bsky")
    assert_equal "did:plc:a", store.resolve("a.bsky").did
  end

  def test_resolve_returns_nil_for_unknown
    store = build_store
    add(store, did: "did:plc:a", handle: "a.bsky")
    assert_nil store.resolve("does-not-exist")
  end

  def test_resolve_prefers_did_over_handle_collision
    store = build_store
    # Pathological case: handle of one account collides with another's did.
    add(store, did: "did:plc:a", handle: "did:plc:b")
    add(store, did: "did:plc:b", handle: "b.bsky")

    assert_equal "did:plc:b", store.resolve("did:plc:b").did
  end

  def test_accounts_json_is_0600
    store = build_store
    add(store, did: "did:plc:a")
    mode = File.stat(@path).mode & 0o777
    assert_equal 0o600, mode
  end

  def test_write_atomic_uses_tmp_then_rename
    store = build_store
    add(store, did: "did:plc:a")
    # After persist completes there must be no leftover tmp file.
    entries = Dir.entries(File.dirname(@path)).reject { |e| e.start_with?(".") }
    assert_equal ["accounts.json"], entries.grep(/accounts/)
  end

  def test_persists_version_field
    store = build_store
    add(store, did: "did:plc:a")
    raw = JSON.parse(File.read(@path))
    assert_equal 1, raw["version"]
  end

  def test_unknown_version_is_treated_as_empty
    FileUtils.mkdir_p(File.dirname(@path))
    File.write(@path, JSON.generate({ "version" => 999, "default" => "did:plc:a", "accounts" => [{ "did" => "did:plc:a", "handle" => "x" }] }))
    store = build_store
    assert_nil store.default
    assert_equal [], store.accounts
  end

  def test_malformed_json_is_treated_as_empty
    FileUtils.mkdir_p(File.dirname(@path))
    File.write(@path, "{not-json")
    store = build_store
    assert_nil store.default
    assert_equal [], store.accounts
  end

  def test_update_handle_updates_target_did
    store = build_store
    add(store, did: "did:plc:a", handle: "old.bsky")
    store.update_handle(did: "did:plc:a", handle: "new.bsky")
    assert_equal "new.bsky", build_store.resolve("did:plc:a").handle
  end

  def test_update_handle_is_noop_for_unknown_did
    store = build_store
    add(store, did: "did:plc:a", handle: "old.bsky")
    store.update_handle(did: "did:plc:zzz", handle: "whatever")
    # No exception, original handle unchanged.
    assert_equal "old.bsky", build_store.resolve("did:plc:a").handle
  end

  def test_update_handle_noop_when_same_value
    store = build_store
    add(store, did: "did:plc:a", handle: "same.bsky")
    mtime_before = File.mtime(@path)
    sleep 0.01
    store.update_handle(did: "did:plc:a", handle: "same.bsky")
    assert_equal mtime_before.to_f, File.mtime(@path).to_f
  end

  def test_accounts_are_returned_in_added_at_order
    store = build_store
    add(store, did: "did:plc:b", added_at: Time.utc(2026, 5, 18, 12, 0, 0))
    add(store, did: "did:plc:a", added_at: Time.utc(2026, 5, 1, 0, 0, 0))
    add(store, did: "did:plc:c", added_at: Time.utc(2026, 6, 1, 0, 0, 0))

    reloaded = build_store
    assert_equal ["did:plc:a", "did:plc:b", "did:plc:c"], reloaded.accounts.map(&:did)
  end

  def test_self_heal_adopts_orphan_session_dir
    # accounts.json absent, but accounts/<did>/session.json exists from a
    # partial login. Construction should bring the orphan into accounts.json.
    did = "did:plc:orphan"
    session_path = Tempest::AccountPaths.session_path(@env, did: did)
    FileUtils.mkdir_p(File.dirname(session_path), mode: 0o700)
    File.write(session_path, JSON.generate(
      "identifier" => "orphan.bsky.social",
      "pds_host" => "https://bsky.social",
      "did" => did,
      "handle" => "orphan.bsky.social",
      "access_jwt" => "a",
      "refresh_jwt" => "r",
    ))

    store = build_store
    refute_nil store.resolve(did)
    assert_equal "orphan.bsky.social", store.resolve(did).handle
    assert_equal did, store.default
  end

  def test_self_heal_skips_when_session_json_corrupt
    did = "did:plc:broken"
    session_path = Tempest::AccountPaths.session_path(@env, did: did)
    FileUtils.mkdir_p(File.dirname(session_path), mode: 0o700)
    File.write(session_path, "{not-json")

    store = build_store
    assert_nil store.resolve(did)
  end

  def test_account_entry_without_session_dir_is_preserved
    store = build_store
    add(store, did: "did:plc:a", handle: "a.bsky")
    # No session.json on disk. Should still be in accounts on reload.
    refute_nil build_store.resolve("did:plc:a")
  end
end
