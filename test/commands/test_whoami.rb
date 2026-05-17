require_relative "../test_helper"
require "stringio"
require "json"
require "tempest/commands/whoami"
require "tempest/session"

class TestCommandsWhoami < Minitest::Test
  def fake_session
    Tempest::Session.new(
      access_jwt: "a", refresh_jwt: "r",
      did: "did:plc:abc", handle: "asonas.bsky.social",
      pds_host: "https://bsky.social",
    )
  end

  def test_default_output_is_handle_and_did
    out = StringIO.new
    status = Tempest::Commands::Whoami.call(
      argv: [], session: fake_session, stdout: out, stderr: StringIO.new,
    )
    assert_equal 0, status
    assert_equal "@asonas.bsky.social (did:plc:abc)\n", out.string
  end

  def test_did_flag_outputs_only_did
    out = StringIO.new
    Tempest::Commands::Whoami.call(argv: ["--did"], session: fake_session, stdout: out, stderr: StringIO.new)
    assert_equal "did:plc:abc\n", out.string
  end

  def test_handle_flag_outputs_only_handle
    out = StringIO.new
    Tempest::Commands::Whoami.call(argv: ["--handle"], session: fake_session, stdout: out, stderr: StringIO.new)
    assert_equal "asonas.bsky.social\n", out.string
  end

  def test_json_flag_outputs_object_with_handle_did_pds_host
    out = StringIO.new
    Tempest::Commands::Whoami.call(argv: ["--json"], session: fake_session, stdout: out, stderr: StringIO.new)
    payload = JSON.parse(out.string)
    assert_equal "asonas.bsky.social", payload["handle"]
    assert_equal "did:plc:abc", payload["did"]
    assert_equal "https://bsky.social", payload["pds_host"]
  end

  def test_did_and_handle_are_mutually_exclusive
    err = StringIO.new
    status = Tempest::Commands::Whoami.call(
      argv: ["--did", "--handle"], session: fake_session, stdout: StringIO.new, stderr: err,
    )
    assert_equal 64, status
    assert_match(/mutually exclusive/, err.string)
  end
end
