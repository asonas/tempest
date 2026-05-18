require_relative "test_helper"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"
require "tempest/account_paths"
require "tempest/accounts_store"
require "tempest/commands/accounts"

class TestCommandsAccounts < Minitest::Test
  def with_env
    Dir.mktmpdir do |dir|
      yield({ "XDG_CONFIG_HOME" => dir, "HOME" => dir, "TEMPEST_NO_LOG" => "1" }, dir)
    end
  end

  def write_accounts(env, default:, accounts:)
    FileUtils.mkdir_p(File.dirname(Tempest::AccountPaths.accounts_json_path(env)))
    File.write(Tempest::AccountPaths.accounts_json_path(env), JSON.generate(
      "version" => 1, "default" => default, "accounts" => accounts,
    ))
  end

  def call(env, argv)
    stdout = StringIO.new
    stderr = StringIO.new
    code = Tempest::Commands::Accounts.call(
      argv: argv, env: env, stdout: stdout, stderr: stderr,
    )
    [code, stdout.string, stderr.string]
  end

  def test_list_with_no_accounts_outputs_hint
    with_env do |env, _|
      code, out, _err = call(env, ["list"])
      assert_equal 0, code
      assert_match(/no accounts/, out)
    end
  end

  def test_list_outputs_each_account_with_default_marker
    with_env do |env, _|
      write_accounts(env, default: "did:plc:a", accounts: [
        { "did" => "did:plc:a", "handle" => "a.bsky", "identifier" => "a.bsky",
          "pds_host" => "https://bsky.social", "added_at" => "2026-05-18T00:00:00.000000Z" },
        { "did" => "did:plc:b", "handle" => "b.bsky", "identifier" => "b.bsky",
          "pds_host" => "https://pds.example", "added_at" => "2026-05-19T00:00:00.000000Z" },
      ])
      code, out, _err = call(env, ["list"])
      assert_equal 0, code
      lines = out.lines.map(&:chomp)
      assert_includes lines[0], "* @a.bsky"
      assert_includes lines[0], "did:plc:a"
      assert_includes lines[0], "https://bsky.social"
      assert_includes lines[0], "added 2026-05-18"
      assert_includes lines[1], "  @b.bsky"
      refute_includes lines[1], "*"
    end
  end

  def test_list_json_format
    with_env do |env, _|
      write_accounts(env, default: "did:plc:a", accounts: [
        { "did" => "did:plc:a", "handle" => "a.bsky", "identifier" => "a.bsky",
          "pds_host" => "https://bsky.social", "added_at" => "2026-05-18T00:00:00.000000Z" },
      ])
      code, out, _err = call(env, ["list", "--format=json"])
      assert_equal 0, code
      data = JSON.parse(out)
      assert_equal "did:plc:a", data["default"]
      assert_equal 1, data["accounts"].length
      assert_equal "a.bsky", data["accounts"].first["handle"]
    end
  end

  def test_set_default_changes_default
    with_env do |env, _|
      write_accounts(env, default: "did:plc:a", accounts: [
        { "did" => "did:plc:a", "handle" => "a.bsky", "identifier" => "a.bsky",
          "pds_host" => "https://bsky.social", "added_at" => "2026-05-18T00:00:00.000000Z" },
        { "did" => "did:plc:b", "handle" => "b.bsky", "identifier" => "b.bsky",
          "pds_host" => "https://bsky.social", "added_at" => "2026-05-19T00:00:00.000000Z" },
      ])
      code, _out, _err = call(env, ["set-default", "b.bsky"])
      assert_equal 0, code

      data = JSON.parse(File.read(Tempest::AccountPaths.accounts_json_path(env)))
      assert_equal "did:plc:b", data["default"]
    end
  end

  def test_set_default_rejects_unknown_user
    with_env do |env, _|
      write_accounts(env, default: "did:plc:a", accounts: [
        { "did" => "did:plc:a", "handle" => "a.bsky", "identifier" => "a.bsky",
          "pds_host" => "https://bsky.social", "added_at" => "2026-05-18T00:00:00.000000Z" },
      ])
      code, _out, err = call(env, ["set-default", "nope.bsky"])
      assert_equal 2, code
      assert_match(/unknown user: nope.bsky/, err)
    end
  end

  def test_set_default_requires_argument
    with_env do |env, _|
      code, _out, err = call(env, ["set-default"])
      assert_equal 64, code
      assert_match(/usage:/, err)
    end
  end

  def test_no_subcommand_shows_usage
    with_env do |env, _|
      code, out, _err = call(env, [])
      assert_equal 64, code
      assert_match(/usage:/, out)
    end
  end

  def test_unknown_subcommand_errors
    with_env do |env, _|
      code, _out, err = call(env, ["foo"])
      assert_equal 64, code
      assert_match(/unknown accounts subcommand: foo/, err)
    end
  end

  def test_list_invalid_format_with_empty_store
    with_env do |env, _|
      code, _out, err = call(env, ["list", "--format=yaml"])
      assert_equal 64, code
      assert_match(/invalid --format/, err)
    end
  end

  def test_list_invalid_format_with_non_empty_store
    with_env do |env, _|
      write_accounts(env, default: "did:plc:a", accounts: [
        { "did" => "did:plc:a", "handle" => "a.bsky", "identifier" => "a.bsky",
          "pds_host" => "https://bsky.social", "added_at" => "2026-05-18T00:00:00.000000Z" },
      ])
      code, _out, err = call(env, ["list", "--format=yaml"])
      assert_equal 64, code
      assert_match(/invalid --format/, err)
    end
  end
end
