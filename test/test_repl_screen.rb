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

  # Without locking, concurrent writers can interleave the escape sequences
  # emitted by insert_above_prompt; in a real terminal one thread's \r\e[2K can
  # land between another thread's text-write and \n, clobbering the line that
  # was just written (the Jetstream thread eating a synchronous "posted: ..."
  # line, etc.). The invariant we pin: every call's sequence appears
  # contiguously in the IO byte stream — i.e., between a thread's \e7 and its
  # matching \e8, no other thread's bytes appear.
  def test_puts_emits_atomic_sequences_across_concurrent_writers
    io = FakeTTY.new
    # Force yields between every IO write so threads actually interleave under
    # the GVL. Without this the race is hidden by Ruby's scheduler.
    io.singleton_class.prepend(Module.new do
      def print(*args)
        Thread.pass
        super
      end
    end)

    screen = Tempest::REPL::Screen.new(io: io, rows: 24)
    screen.enable
    io.truncate(0); io.rewind

    lines = (1..50).map { |i| "line-#{i}" }
    threads = lines.each_slice(10).map do |chunk|
      Thread.new { chunk.each { |line| screen.puts line } }
    end
    threads.each(&:join)

    output = io.string
    # Walk segments delimited by \e7 ... \e8 and ensure each segment contains
    # exactly one line-N token. If two threads' bytes interleaved, a segment
    # would either contain two tokens or be missing one.
    segments = output.scan(/\e7.*?\e8/m)
    assert_equal lines.length, segments.length, "expected one DECSC/DECRC segment per puts"
    segments.each do |seg|
      tokens = seg.scan(/line-\d+/)
      assert_equal 1, tokens.length, "segment carried #{tokens.inspect}, expected exactly one"
    end
  end

  def test_puts_wraps_line_wider_than_cols_into_multiple_chunks
    io = FakeTTY.new
    screen = Tempest::REPL::Screen.new(io: io, rows: 24, cols: 20)
    screen.enable
    io.truncate(0); io.rewind

    # 30 ascii chars, cols=20 -> two chunks
    long = "0123456789ABCDEFGHIJKLMNOPQRST"
    screen.puts long

    output = io.string
    # Both chunks must land inside the scrolling region.
    assert_includes output, "0123456789ABCDEFGHIJ"
    assert_includes output, "KLMNOPQRST"
    # Each chunk should be preceded by a move-to-last-row and a clear-line, so
    # the terminal scrolls the region instead of spilling onto the prompt row.
    move_clear_pairs = output.scan(/\e\[23;1H\r\e\[2K/).length
    assert_operator move_clear_pairs, :>=, 2
  end

  def test_puts_does_not_wrap_when_line_fits_in_cols
    io = FakeTTY.new
    screen = Tempest::REPL::Screen.new(io: io, rows: 24, cols: 80)
    screen.enable
    io.truncate(0); io.rewind

    screen.puts "hello"
    assert_equal 1, io.string.scan(/\e\[23;1H/).length
  end

  def test_puts_wraps_cjk_lines_using_display_width_not_char_count
    io = FakeTTY.new
    screen = Tempest::REPL::Screen.new(io: io, rows: 24, cols: 10)
    screen.enable
    io.truncate(0); io.rewind

    # Each CJK char is width 2; 8 chars = width 16 > cols 10, so it must wrap.
    screen.puts "日本語テキスト!"
    assert_operator io.string.scan(/\e\[23;1H/).length, :>=, 2
  end
end
