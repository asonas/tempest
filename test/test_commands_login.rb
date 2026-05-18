require_relative "test_helper"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"
require "tempest/account_paths"
require "tempest/accounts_store"
require "tempest/commands/login"
require "tempest/session"
require "tempest/session_store"

class TestCommandsLogin < Minitest::Test
  def with_env
    Dir.mktmpdir do |dir|
      yield({ "XDG_CONFIG_HOME" => dir, "HOME" => dir, "TEMPEST_NO_LOG" => "1" }, dir)
    end
  end

  def make_session(did:, handle:, identifier: nil, pds_host: "https://bsky.social")
    Tempest::Session.new(
      access_jwt: "a", refresh_jwt: "r",
      did: did, handle: handle,
      pds_host: pds_host, identifier: identifier,
    )
  end

  # Fakes stdin so we can drive identifier and password without actual TTY.
  class FakeStdin
    def initialize(lines)
      @lines = lines.dup
    end

    def gets
      @lines.shift
    end

    def noecho
      yield self
    end
  end

  def run_login(env:, stdin_lines:, factory:, argv: [])
    stdout = StringIO.new
    stderr = StringIO.new
    code = Tempest::Commands::Login.call(
      argv: argv, env: env,
      stdout: stdout, stderr: stderr,
      stdin: FakeStdin.new(stdin_lines),
      session_factory: factory,
    )
    [code, stdout.string, stderr.string]
  end

  def test_creates_session_json_and_accounts_entry
    with_env do |env, _dir|
      factory = ->(config, auth_factor_token: nil) do
        assert_equal "asonas.bsky.social", config.identifier
        assert_equal "app-password", config.app_password
        make_session(did: "did:plc:abc", handle: "asonas.bsky.social", identifier: config.identifier)
      end

      code, _out, _err = run_login(
        env: env,
        stdin_lines: ["asonas.bsky.social\n", "app-password\n"],
        factory: factory,
      )

      assert_equal 0, code
      assert File.exist?(File.join(env["XDG_CONFIG_HOME"], "tempest", "accounts", "did:plc:abc", "session.json"))
      accounts = JSON.parse(File.read(File.join(env["XDG_CONFIG_HOME"], "tempest", "accounts.json")))
      assert_equal "did:plc:abc", accounts["default"]
      assert_equal "asonas.bsky.social", accounts["accounts"].first["handle"]
    end
  end

  def test_emits_signing_in_message_to_stdout
    with_env do |env, _dir|
      factory = ->(*, **) { make_session(did: "did:plc:abc", handle: "x") }
      _code, out, _err = run_login(
        env: env, stdin_lines: ["x.bsky\n", "p\n"], factory: factory,
      )
      assert_match(/signing in/, out)
      assert_match(/logged in as @x/, out)
    end
  end

  def test_ignores_env_identifier_and_password
    with_env do |env, _dir|
      env_with_creds = env.merge("TEMPEST_IDENTIFIER" => "env.bsky", "TEMPEST_APP_PASSWORD" => "env-pw")
      seen = nil
      factory = ->(config, auth_factor_token: nil) do
        seen = config.identifier
        make_session(did: "did:plc:abc", handle: "from-stdin.bsky")
      end

      run_login(
        env: env_with_creds,
        stdin_lines: ["stdin.bsky\n", "stdin-pw\n"],
        factory: factory,
      )

      assert_equal "stdin.bsky", seen
    end
  end

  def test_returns_64_when_identifier_blank
    with_env do |env, _dir|
      factory = ->(*, **) { flunk "factory should not be called" }
      code, _out, err = run_login(env: env, stdin_lines: ["\n", "p\n"], factory: factory)
      assert_equal 64, code
      assert_match(/identifier required/, err)
    end
  end

  def test_returns_64_when_password_blank
    with_env do |env, _dir|
      factory = ->(*, **) { flunk "factory should not be called" }
      code, _out, err = run_login(env: env, stdin_lines: ["x.bsky\n", "\n"], factory: factory)
      assert_equal 64, code
      assert_match(/app password required/, err)
    end
  end

  def test_propagates_authentication_error
    with_env do |env, _dir|
      factory = ->(*, **) { raise Tempest::AuthenticationError.new("bad creds", code: "InvalidLogin") }
      code, _out, err = run_login(env: env, stdin_lines: ["x.bsky\n", "p\n"], factory: factory)
      assert_equal 3, code
      assert_match(/login failed/, err)
    end
  end

  def test_does_not_write_session_or_accounts_on_failure
    with_env do |env, _dir|
      factory = ->(*, **) { raise Tempest::AuthenticationError.new("nope", code: "InvalidLogin") }
      run_login(env: env, stdin_lines: ["x.bsky\n", "p\n"], factory: factory)

      refute File.exist?(File.join(env["XDG_CONFIG_HOME"], "tempest", "accounts.json"))
    end
  end

  def test_overwrites_existing_did
    with_env do |env, _dir|
      # Pre-seed accounts.json + per-DID session.json with one DID.
      did = "did:plc:abc"
      FileUtils.mkdir_p(Tempest::AccountPaths.account_dir(env, did: did), mode: 0o700)
      File.write(Tempest::AccountPaths.accounts_json_path(env), JSON.generate(
        "version" => 1, "default" => did,
        "accounts" => [{ "did" => did, "handle" => "old.bsky", "identifier" => "old.bsky",
                         "pds_host" => "https://bsky.social", "added_at" => "2026-01-01T00:00:00.000000Z" }],
      ))

      factory = ->(*, **) { make_session(did: did, handle: "new.bsky") }
      code, _out, _err = run_login(env: env, stdin_lines: ["new.bsky\n", "p\n"], factory: factory)

      assert_equal 0, code
      accounts = JSON.parse(File.read(Tempest::AccountPaths.accounts_json_path(env)))
      assert_equal "new.bsky", accounts["accounts"].first["handle"]
      # added_at preserved.
      assert_equal "2026-01-01T00:00:00.000000Z", accounts["accounts"].first["added_at"]
    end
  end

  def test_pds_host_flag
    with_env do |env, _dir|
      captured = nil
      factory = ->(config, auth_factor_token: nil) do
        captured = config.pds_host
        make_session(did: "did:plc:abc", handle: "x", pds_host: config.pds_host)
      end

      code, _out, _err = run_login(
        env: env,
        argv: ["--pds-host=https://pds.example"],
        stdin_lines: ["x.bsky\n", "p\n"],
        factory: factory,
      )

      assert_equal 0, code
      assert_equal "https://pds.example", captured
      accounts = JSON.parse(File.read(Tempest::AccountPaths.accounts_json_path(env)))
      assert_equal "https://pds.example", accounts["accounts"].first["pds_host"]
    end
  end

  def test_handles_2fa_challenge
    with_env do |env, _dir|
      attempts = 0
      factory = ->(_, auth_factor_token: nil) do
        attempts += 1
        if attempts == 1
          raise Tempest::AuthenticationError.new("need code", code: "AuthFactorTokenRequired")
        end
        assert_equal "12345", auth_factor_token
        make_session(did: "did:plc:abc", handle: "x")
      end

      code, out, _err = run_login(
        env: env,
        stdin_lines: ["x.bsky\n", "p\n", "12345\n"],
        factory: factory,
      )

      assert_equal 0, code
      assert_match(/code:/, out)
    end
  end
end
