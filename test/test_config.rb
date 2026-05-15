require_relative "test_helper"
require "tempest/config"

class TestConfig < Minitest::Test
  def test_loads_identifier_and_app_password_from_env
    env = {
      "TEMPEST_IDENTIFIER" => "asonas.bsky.social",
      "TEMPEST_APP_PASSWORD" => "xxxx-xxxx-xxxx-xxxx",
    }
    config = Tempest::Config.from_env(env)

    assert_equal "asonas.bsky.social", config.identifier
    assert_equal "xxxx-xxxx-xxxx-xxxx", config.app_password
  end

  def test_defaults_pds_host_to_bsky_social
    env = {
      "TEMPEST_IDENTIFIER" => "asonas.bsky.social",
      "TEMPEST_APP_PASSWORD" => "xxxx",
    }
    config = Tempest::Config.from_env(env)

    assert_equal "https://bsky.social", config.pds_host
  end

  def test_pds_host_override_via_env
    env = {
      "TEMPEST_IDENTIFIER" => "asonas.example.com",
      "TEMPEST_APP_PASSWORD" => "xxxx",
      "TEMPEST_PDS_HOST" => "https://pds.example.com",
    }
    config = Tempest::Config.from_env(env)

    assert_equal "https://pds.example.com", config.pds_host
  end

  def test_raises_when_identifier_missing
    env = { "TEMPEST_APP_PASSWORD" => "xxxx" }

    error = assert_raises(Tempest::Config::MissingValue) { Tempest::Config.from_env(env) }
    assert_match(/TEMPEST_IDENTIFIER/, error.message)
  end

  def test_raises_when_app_password_missing
    env = { "TEMPEST_IDENTIFIER" => "asonas.bsky.social" }

    error = assert_raises(Tempest::Config::MissingValue) { Tempest::Config.from_env(env) }
    assert_match(/TEMPEST_APP_PASSWORD/, error.message)
  end
end
