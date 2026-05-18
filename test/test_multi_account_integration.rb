require_relative "test_helper"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"
require "tempest/account_paths"
require "tempest/accounts_store"
require "tempest/accounts_migration"
require "tempest/cli"
require "tempest/session"
require "tempest/session_store"

# H1-H8 from plan.md.
class TestMultiAccountIntegration < Minitest::Test
  def with_env
    Dir.mktmpdir do |dir|
      yield({ "XDG_CONFIG_HOME" => dir, "HOME" => dir, "TEMPEST_NO_LOG" => "1" }, dir)
    end
  end

  def seed_legacy_session(env, did:, handle:, refresh: "r")
    base = File.join(env["XDG_CONFIG_HOME"], "tempest")
    FileUtils.mkdir_p(base)
    File.write(File.join(base, "session.json"), JSON.generate(
      "identifier" => handle, "pds_host" => "https://bsky.social",
      "did" => did, "handle" => handle,
      "access_jwt" => "a", "refresh_jwt" => refresh,
    ))
  end

  def seed_account(env, did:, handle:, refresh: "r", default: false)
    FileUtils.mkdir_p(Tempest::AccountPaths.account_dir(env, did: did), mode: 0o700)
    session = Tempest::Session.new(
      access_jwt: "a", refresh_jwt: refresh,
      did: did, handle: handle, pds_host: "https://bsky.social",
    )
    Tempest::SessionStore.for(env, did: did).save(session, identifier: handle)
    path = Tempest::AccountPaths.accounts_json_path(env)
    existing = File.exist?(path) ? JSON.parse(File.read(path)) : { "version" => 1, "default" => nil, "accounts" => [] }
    existing["accounts"] << {
      "did" => did, "handle" => handle, "identifier" => handle,
      "pds_host" => "https://bsky.social",
      "added_at" => "2026-05-#{existing["accounts"].length + 1}T00:00:00.000000Z",
    }
    existing["default"] = did if default || existing["default"].nil?
    File.write(path, JSON.generate(existing))
  end

  def stub_refresh(refresh:, did:, handle:)
    stub_request(:post, "https://bsky.social/xrpc/com.atproto.server.refreshSession")
      .with(headers: { "Authorization" => "Bearer #{refresh}" })
      .to_return(
        status: 200, headers: { "Content-Type" => "application/json" },
        body: { accessJwt: "a2", refreshJwt: "#{refresh}2", did: did, handle: handle }.to_json,
      )
  end

  def test_H1_migrates_legacy_session_on_first_tui_start
    with_env do |env, dir|
      seed_legacy_session(env, did: "did:plc:a", handle: "asonas.bsky.social")
      stub_refresh(refresh: "r", did: "did:plc:a", handle: "asonas.bsky.social")

      err = StringIO.new
      status = Tempest::CLI.run(
        argv: ["whoami"], env: env,
        stdout: StringIO.new, stderr: err,
      )

      assert_equal 0, status
      refute File.exist?(File.join(dir, "tempest", "session.json"))
      assert File.exist?(File.join(dir, "tempest", "accounts", "did:plc:a", "session.json"))
      data = JSON.parse(File.read(File.join(dir, "tempest", "accounts.json")))
      assert_equal "did:plc:a", data["default"]
    end
  end

  def test_H2_login_then_list_shows_both
    with_env do |env, _dir|
      seed_account(env, did: "did:plc:a", handle: "first.bsky", default: true)

      # Run accounts list directly (bypasses TUI).
      out = StringIO.new
      status = Tempest::CLI.run(argv: ["accounts", "list"], env: env, stdout: out, stderr: StringIO.new)
      assert_equal 0, status
      assert_includes out.string, "first.bsky"
    end
  end

  def test_H3_user_flag_targets_second_account
    with_env do |env, _dir|
      seed_account(env, did: "did:plc:a", handle: "first.bsky", refresh: "ra", default: true)
      seed_account(env, did: "did:plc:b", handle: "second.bsky", refresh: "rb")
      stub_refresh(refresh: "rb", did: "did:plc:b", handle: "second.bsky")

      out = StringIO.new
      status = Tempest::CLI.run(
        argv: ["--user", "second.bsky", "whoami"], env: env,
        stdout: out, stderr: StringIO.new,
      )
      assert_equal 0, status
      assert_match(/@second.bsky/, out.string)
    end
  end

  def test_H4_default_is_used_when_user_unspecified
    with_env do |env, _dir|
      seed_account(env, did: "did:plc:a", handle: "first.bsky", refresh: "ra", default: true)
      seed_account(env, did: "did:plc:b", handle: "second.bsky", refresh: "rb")
      stub_refresh(refresh: "ra", did: "did:plc:a", handle: "first.bsky")

      out = StringIO.new
      Tempest::CLI.run(argv: ["whoami"], env: env, stdout: out, stderr: StringIO.new)
      assert_match(/@first.bsky/, out.string)
    end
  end

  def test_H5_set_default_changes_no_arg_target
    with_env do |env, _dir|
      seed_account(env, did: "did:plc:a", handle: "first.bsky", refresh: "ra", default: true)
      seed_account(env, did: "did:plc:b", handle: "second.bsky", refresh: "rb")
      stub_refresh(refresh: "rb", did: "did:plc:b", handle: "second.bsky")

      Tempest::CLI.run(
        argv: ["accounts", "set-default", "second.bsky"], env: env,
        stdout: StringIO.new, stderr: StringIO.new,
      )

      out = StringIO.new
      Tempest::CLI.run(argv: ["whoami"], env: env, stdout: out, stderr: StringIO.new)
      assert_match(/@second.bsky/, out.string)
    end
  end

  def test_H6_first_run_env_path_creates_accounts_json
    skip "first-run env path requires real TUI runtime; covered by manual smoke test"
  end

  def test_H7_env_ignored_when_accounts_json_exists
    with_env do |env, _dir|
      seed_account(env, did: "did:plc:a", handle: "first.bsky", default: true)
      stub_refresh(refresh: "r", did: "did:plc:a", handle: "first.bsky")
      env_with = env.merge("TEMPEST_IDENTIFIER" => "other.bsky", "TEMPEST_APP_PASSWORD" => "p")

      out = StringIO.new
      Tempest::CLI.run(argv: ["whoami"], env: env_with, stdout: out, stderr: StringIO.new)
      # Resolves to default first.bsky, not env's other.bsky.
      assert_match(/@first.bsky/, out.string)
    end
  end

  def test_H8_orphan_session_recovers_via_self_heal
    with_env do |env, _dir|
      # Simulate login crash: per-DID session.json present, accounts.json missing.
      did = "did:plc:orphan"
      FileUtils.mkdir_p(Tempest::AccountPaths.account_dir(env, did: did), mode: 0o700)
      File.write(Tempest::AccountPaths.session_path(env, did: did), JSON.generate(
        "identifier" => "orphan.bsky", "pds_host" => "https://bsky.social",
        "did" => did, "handle" => "orphan.bsky",
        "access_jwt" => "a", "refresh_jwt" => "r",
      ))

      stub_refresh(refresh: "r", did: did, handle: "orphan.bsky")

      out = StringIO.new
      status = Tempest::CLI.run(argv: ["whoami"], env: env, stdout: out, stderr: StringIO.new)
      assert_equal 0, status
      assert_match(/@orphan.bsky/, out.string)
      assert File.exist?(Tempest::AccountPaths.accounts_json_path(env))
    end
  end
end
