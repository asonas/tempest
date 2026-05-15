require_relative "test_helper"

class TestVersion < Minitest::Test
  def test_version_is_defined
    refute_nil Tempest::VERSION
    assert_match(/\A\d+\.\d+\.\d+\z/, Tempest::VERSION)
  end
end
