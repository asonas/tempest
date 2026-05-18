require_relative "../test_helper"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"
require "tempest/account_paths"
require "tempest/accounts_store"
require "tempest/commands/base"
require "tempest/session"
require "tempest/session_store"
require "tempest/config"

class TestCommandsBase < Minitest::Test
  def with_accounts_dir(&block)
    Dir.mktmpdir do |dir|
      env = { "XDG_CONFIG_HOME" => dir, "HOME" => dir, "TEMPEST_NO_LOG" => "1" }
      block.call(env, dir)
    end
  end

  def seed_account(env, did:, handle:, identifier: nil, access: "a", refresh: "r")
    identifier ||= handle
    session = Tempest::Session.new(
      access_jwt: access,
      refresh_jwt: refresh,
      did: did,
      handle: handle,
      pds_host: "https://bsky.social",
    )
    FileUtils.mkdir_p(Tempest::AccountPaths.account_dir(env, did: did), mode: 0o700)
    Tempest::SessionStore.for(env, did: did).save(session, identifier: identifier)
    File.write(Tempest::AccountPaths.accounts_json_path(env), JSON.generate(
      "version" => 1,
      "default" => did,
      "accounts" => [{
        "did" => did,
        "handle" => handle,
        "identifier" => identifier,
        "pds_host" => "https://bsky.social",
        "added_at" => "2026-05-18T00:00:00.000000Z",
      }],
    ))
  end

  def test_auth_returns_session_when_cached_session_refreshes_successfully
    with_accounts_dir do |env, _dir|
      seed_account(env, did: "did:plc:x", handle: "asonas.bsky.social", refresh: "old-refresh")

      stub_request(:post, "https://bsky.social/xrpc/com.atproto.server.refreshSession")
        .with(headers: { "Authorization" => "Bearer old-refresh" })
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { accessJwt: "new", refreshJwt: "new-refresh", did: "did:plc:x", handle: "asonas.bsky.social" }.to_json,
        )

      session = Tempest::Commands::Base.authenticate(env: env, stderr: StringIO.new)
      refute_nil session
      assert_equal "asonas.bsky.social", session.handle
    end
  end

  def test_auth_returns_nil_and_writes_error_when_no_cache
    with_accounts_dir do |env, _dir|
      err = StringIO.new
      session = Tempest::Commands::Base.authenticate(env: env, stderr: err)
      assert_nil session
      assert_match(/no accounts configured/, err.string)
    end
  end

  def test_auth_returns_nil_when_unknown_user
    with_accounts_dir do |env, _dir|
      seed_account(env, did: "did:plc:x", handle: "asonas.bsky.social")
      err = StringIO.new
      session = Tempest::Commands::Base.authenticate(env: env, user: "nope.bsky", stderr: err)
      assert_nil session
      assert_match(/unknown user: nope.bsky/, err.string)
    end
  end

  def test_auth_returns_nil_when_session_file_missing
    with_accounts_dir do |env, _dir|
      FileUtils.mkdir_p(File.dirname(Tempest::AccountPaths.accounts_json_path(env)))
      File.write(Tempest::AccountPaths.accounts_json_path(env), JSON.generate(
        "version" => 1,
        "default" => "did:plc:gone",
        "accounts" => [{
          "did" => "did:plc:gone",
          "handle" => "gone.bsky",
          "identifier" => "gone.bsky",
          "pds_host" => "https://bsky.social",
          "added_at" => "2026-05-18T00:00:00.000000Z",
        }],
      ))
      err = StringIO.new
      session = Tempest::Commands::Base.authenticate(env: env, stderr: err)
      assert_nil session
      assert_match(/session for @gone.bsky missing/, err.string)
    end
  end

  class FakeIO
    def initialize(tty:); @tty = tty; end
    def tty?; @tty; end
  end

  def test_default_format_is_json_when_stdout_is_not_a_tty
    fmt = Tempest::Commands::Base.default_format(stdout: FakeIO.new(tty: false), env: {})
    assert_equal :json, fmt
  end

  def test_default_format_is_line_when_stdout_is_a_tty_and_no_color_unset
    fmt = Tempest::Commands::Base.default_format(stdout: FakeIO.new(tty: true), env: {})
    assert_equal :line, fmt
  end

  def test_exit_code_for_config_missing_returns_2
    e = Tempest::Config::MissingValue.new("missing")
    assert_equal 2, Tempest::Commands::Base.exit_code_for(e)
  end

  def test_exit_code_for_auth_returns_3
    e = Tempest::AuthenticationError.new("nope", code: "x")
    assert_equal 3, Tempest::Commands::Base.exit_code_for(e)
  end

  def test_exit_code_for_api_returns_4
    e = Tempest::APIError.new(503, "down")
    assert_equal 4, Tempest::Commands::Base.exit_code_for(e)
  end

  def test_exit_code_for_argument_error_returns_64
    assert_equal 64, Tempest::Commands::Base.exit_code_for(ArgumentError.new("bad flag"))
  end

  def test_exit_code_for_unknown_returns_1
    assert_equal 1, Tempest::Commands::Base.exit_code_for(StandardError.new("oops"))
  end
end
