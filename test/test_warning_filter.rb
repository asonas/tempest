require "test_helper"
require "tempest/warning_filter"

class TestWarningFilter < Minitest::Test
  def test_suppress_matches_internal_io_buffer_warning
    msg = "<internal:io>:63: warning: IO::Buffer is experimental and " \
          "both the Ruby and C interface may change in the future!\n"
    assert Tempest::WarningFilter.suppress?(msg)
  end

  def test_suppress_matches_resolv_path_io_buffer_warning
    msg = "/Users/x/.rbenv/versions/4.0.3/lib/ruby/4.0.3/resolv.rb:123: " \
          "warning: IO::Buffer is experimental\n"
    assert Tempest::WarningFilter.suppress?(msg)
  end

  def test_suppress_does_not_match_unrelated_messages
    refute Tempest::WarningFilter.suppress?("plain warning\n")
    refute Tempest::WarningFilter.suppress?("resolv.rb: warning: deprecated method\n")
    refute Tempest::WarningFilter.suppress?("other.rb: IO::Buffer was used\n")
  end

  def test_suppress_handles_non_string_input
    refute Tempest::WarningFilter.suppress?(nil)
    refute Tempest::WarningFilter.suppress?(123)
  end

  def test_warn_drops_suppressed_messages
    receiver = build_receiver
    receiver.send(:warn, "<internal:io>:63: warning: IO::Buffer is experimental\n")
    assert_empty receiver.captured
  end

  def test_warn_passes_through_other_messages
    receiver = build_receiver
    receiver.send(:warn, "plain warning\n")
    assert_equal ["plain warning\n"], receiver.captured.map(&:first)
  end

  def test_warn_forwards_category_keyword
    receiver = build_receiver
    receiver.send(:warn, "some warning\n", category: :deprecated)
    assert_equal [["some warning\n", { category: :deprecated }]], receiver.captured
  end

  def test_install_is_idempotent
    Tempest::WarningFilter.install!
    Tempest::WarningFilter.install!
    count = Warning.singleton_class.ancestors.count { |a| a == Tempest::WarningFilter }
    assert_equal 1, count
  end

  private

  def build_receiver
    captured = []
    klass = Class.new do
      define_method(:warn) do |msg, **kw|
        captured << (kw.empty? ? [msg] : [msg, kw])
      end
      public :warn
    end
    klass.prepend(Tempest::WarningFilter)
    instance = klass.new
    instance.singleton_class.define_method(:captured) { captured }
    instance
  end
end
