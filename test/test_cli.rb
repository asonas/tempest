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
end
