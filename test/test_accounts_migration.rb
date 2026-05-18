require_relative "test_helper"
require "tempest/accounts_migration"
require "tempest/account_paths"
require "fileutils"
require "json"
require "tmpdir"
require "stringio"

class TestAccountsMigration < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir
    @env = { "XDG_CONFIG_HOME" => @tmp }
    @base = File.join(@tmp, "tempest")
    @stderr = StringIO.new
  end

  def teardown
    FileUtils.remove_entry(@tmp) if File.exist?(@tmp)
  end

  def write_legacy_session(payload = nil)
    payload ||= {
      "identifier" => "asonas.bsky.social",
      "pds_host" => "https://bsky.social",
      "did" => "did:plc:abc",
      "handle" => "asonas.bsky.social",
      "access_jwt" => "a",
      "refresh_jwt" => "r",
    }
    FileUtils.mkdir_p(@base)
    File.write(File.join(@base, "session.json"), JSON.generate(payload))
  end

  def run_migration
    Tempest::AccountsMigration.run(env: @env, stderr: @stderr)
  end

  def test_noop_when_nothing_exists
    assert_equal :noop, run_migration
    refute File.exist?(File.join(@base, "accounts.json"))
  end

  def test_skipped_when_accounts_json_already_exists
    FileUtils.mkdir_p(@base)
    File.write(File.join(@base, "accounts.json"), "{}")
    write_legacy_session

    assert_equal :skipped, run_migration
    # Legacy file untouched.
    assert File.exist?(File.join(@base, "session.json"))
  end

  def test_migrate_moves_legacy_session
    write_legacy_session
    assert_equal :migrated, run_migration

    refute File.exist?(File.join(@base, "session.json"))
    assert File.exist?(File.join(@base, "accounts", "did:plc:abc", "session.json"))
  end

  def test_migrate_writes_accounts_json_with_full_metadata
    write_legacy_session
    run_migration

    data = JSON.parse(File.read(File.join(@base, "accounts.json")))
    assert_equal 1, data["version"]
    assert_equal "did:plc:abc", data["default"]
    account = data["accounts"].first
    assert_equal "did:plc:abc", account["did"]
    assert_equal "asonas.bsky.social", account["handle"]
    assert_equal "asonas.bsky.social", account["identifier"]
    assert_equal "https://bsky.social", account["pds_host"]
    refute_nil account["added_at"]
  end

  def test_migrate_moves_cursor_if_present
    write_legacy_session
    File.write(File.join(@base, "cursor.json"), '{"time_us":123,"saved_at":"2026-05-18T00:00:00.000000Z"}')

    run_migration

    refute File.exist?(File.join(@base, "cursor.json"))
    assert File.exist?(File.join(@base, "accounts", "did:plc:abc", "cursor.json"))
  end

  def test_migrate_succeeds_without_cursor
    write_legacy_session
    assert_equal :migrated, run_migration
  end

  def test_migrate_moves_timeline_if_present
    write_legacy_session
    File.write(File.join(@base, "timeline.json"), '{"posts":[],"saved_at":"2026-05-18T00:00:00.000000Z"}')

    run_migration

    refute File.exist?(File.join(@base, "timeline.json"))
    assert File.exist?(File.join(@base, "accounts", "did:plc:abc", "timeline.json"))
  end

  def test_accounts_json_is_0600
    write_legacy_session
    run_migration
    mode = File.stat(File.join(@base, "accounts.json")).mode & 0o777
    assert_equal 0o600, mode
  end

  def test_honors_tempest_session_path_env
    nondefault = File.join(@tmp, "elsewhere")
    FileUtils.mkdir_p(nondefault)
    legacy = File.join(nondefault, "session.json")
    File.write(legacy, JSON.generate(
      "identifier" => "asonas.bsky.social",
      "pds_host" => "https://bsky.social",
      "did" => "did:plc:abc",
      "handle" => "asonas.bsky.social",
      "access_jwt" => "a",
      "refresh_jwt" => "r",
    ))
    env = @env.merge("TEMPEST_SESSION_PATH" => legacy)

    result = Tempest::AccountsMigration.run(env: env, stderr: @stderr)

    assert_equal :migrated, result
    refute File.exist?(legacy)
    assert File.exist?(File.join(@base, "accounts", "did:plc:abc", "session.json"))
  end

  def test_account_dir_permissions_are_0700
    write_legacy_session
    run_migration

    accounts_dir = File.join(@base, "accounts")
    did_dir = File.join(accounts_dir, "did:plc:abc")
    assert_equal 0o700, File.stat(accounts_dir).mode & 0o777
    assert_equal 0o700, File.stat(did_dir).mode & 0o777
  end

  def test_stderr_notice_emitted_only_when_migration_runs
    write_legacy_session
    run_migration
    assert_match(/migrated session/, @stderr.string)
  end

  def test_no_stderr_notice_on_noop
    run_migration
    assert_equal "", @stderr.string
  end

  def test_partial_failure_self_heal_path
    # If accounts/<did>/session.json already exists (e.g. from prior partial run)
    # and accounts.json is still absent, migration treats it as a re-run:
    # the legacy session.json is gone, but accounts.json gets written based on
    # the per-DID file via the orphan path (this case is rare; the simpler
    # outcome we guarantee is that a *second* migration after partial completion
    # cannot crash and leaves a usable accounts.json).
    did_dir = File.join(@base, "accounts", "did:plc:abc")
    FileUtils.mkdir_p(did_dir, mode: 0o700)
    File.write(File.join(did_dir, "session.json"), JSON.generate(
      "identifier" => "asonas.bsky.social",
      "pds_host" => "https://bsky.social",
      "did" => "did:plc:abc",
      "handle" => "asonas.bsky.social",
      "access_jwt" => "a",
      "refresh_jwt" => "r",
    ))
    # No legacy session.json. Migration should be :noop; AccountsStore.new will
    # self-heal on next start.
    result = run_migration
    assert_equal :noop, result
  end
end
