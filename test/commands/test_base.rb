require_relative "../test_helper"
require "stringio"
require "tmpdir"
require "tempest/commands/base"
require "tempest/session"
require "tempest/session_store"
require "tempest/config"

class TestCommandsBase < Minitest::Test
  def test_auth_returns_session_when_cached_session_refreshes_successfully
    Dir.mktmpdir do |dir|
      path = File.join(dir, "session.json")
      seed = Tempest::Session.new(
        access_jwt: "old",
        refresh_jwt: "old-refresh",
        did: "did:plc:x",
        handle: "asonas.bsky.social",
        pds_host: "https://bsky.social",
      )
      Tempest::SessionStore.new(path: path).save(seed, identifier: "asonas.bsky.social")

      def seed.refresh!
        @access_jwt = "new"
        self
      end

      store = Tempest::SessionStore.new(path: path)
      def store.load(**); end
      store.define_singleton_method(:load) { |**_| seed }

      session = Tempest::Commands::Base.authenticate(env: {}, store: store, stderr: StringIO.new)
      assert_equal "asonas.bsky.social", session.handle
    end
  end

  def test_auth_returns_nil_and_writes_error_when_no_cache
    Dir.mktmpdir do |dir|
      store = Tempest::SessionStore.new(path: File.join(dir, "missing.json"))
      err = StringIO.new
      session = Tempest::Commands::Base.authenticate(env: {}, store: store, stderr: err)
      assert_nil session
      assert_match(/no cached session/, err.string)
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
