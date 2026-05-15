require_relative "test_helper"
require "stringio"
require "tempest/cli"

class TestCLI < Minitest::Test
  def test_run_prints_error_and_returns_non_zero_when_env_missing
    err = StringIO.new
    status = Tempest::CLI.run(argv: [], env: {}, stdout: StringIO.new, stderr: err)

    assert status != 0
    assert_match(/TEMPEST_IDENTIFIER/, err.string)
  end

  def test_run_prints_version_when_version_flag
    out = StringIO.new
    status = Tempest::CLI.run(argv: ["--version"], env: {}, stdout: out, stderr: StringIO.new)

    assert_equal 0, status
    assert_match(/tempest #{Regexp.escape(Tempest::VERSION)}/, out.string)
  end

  def test_run_passes_auth_factor_token_from_env
    env = {
      "TEMPEST_IDENTIFIER" => "ason.as",
      "TEMPEST_APP_PASSWORD" => "xxxx",
      "TEMPEST_AUTH_FACTOR_TOKEN" => "ABCDE",
    }
    captured = nil
    fake_session_factory = ->(config, auth_factor_token: nil) do
      captured = auth_factor_token
      raise Tempest::AuthenticationError.new("stop here", code: "stub")
    end

    err = StringIO.new
    Tempest::CLI.run(
      argv: [],
      env: env,
      stdout: StringIO.new,
      stderr: err,
      session_factory: fake_session_factory,
    )

    assert_equal "ABCDE", captured
  end
end
