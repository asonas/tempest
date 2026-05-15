require_relative "test_helper"
require "stringio"
require "tempest/repl/screen"

class TestREPLScreen < Minitest::Test
  class FakeTTY < StringIO
    def tty?
      true
    end
  end

  def test_enable_sets_scrolling_region_and_parks_cursor_on_bottom
    io = FakeTTY.new
    screen = Tempest::REPL::Screen.new(io: io, rows: 24)
    screen.enable

    # DECSTBM (CSI 1;23 r) + cursor to bottom (CSI 24;1 H)
    assert_includes io.string, "\e[1;23r"
    assert_includes io.string, "\e[24;1H"
    assert screen.enabled?
  end

  def test_enable_is_a_noop_on_non_tty
    io = StringIO.new # not a tty
    screen = Tempest::REPL::Screen.new(io: io, rows: 24)
    screen.enable

    refute screen.enabled?
    assert_empty io.string
  end

  def test_disable_resets_scrolling_region
    io = FakeTTY.new
    screen = Tempest::REPL::Screen.new(io: io, rows: 24)
    screen.enable
    io.truncate(0); io.rewind

    screen.disable

    assert_includes io.string, "\e[r"
    refute screen.enabled?
  end

  def test_puts_when_enabled_writes_above_prompt_via_decsc_decrc
    io = FakeTTY.new
    screen = Tempest::REPL::Screen.new(io: io, rows: 24)
    screen.enable
    io.truncate(0); io.rewind

    screen.puts "hello"

    output = io.string
    assert_includes output, "\e7"               # save cursor
    assert_includes output, "\e[23;1H"          # move to last scrolling-region line
    assert_includes output, "hello"
    assert_includes output, "\e8"               # restore cursor
  end

  def test_puts_when_disabled_falls_back_to_clear_line_then_write
    io = StringIO.new # disabled
    screen = Tempest::REPL::Screen.new(io: io, rows: 24)

    screen.puts "hi"

    assert_match(/\A\r\e\[2K/, io.string)
    assert_includes io.string, "hi\n"
  end
end
