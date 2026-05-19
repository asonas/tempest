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

  def test_disable_deletes_kitty_graphics_placements
    io = FakeTTY.new
    screen = Tempest::REPL::Screen.new(io: io, rows: 24)
    screen.enable
    io.truncate(0); io.rewind

    screen.disable

    assert_includes io.string, "\e_Ga=d,q=2\e\\"
  end

  def test_suspend_resets_scrolling_region_but_preserves_kitty_graphics
    # Suspend is used when handing the terminal off to $EDITOR for `:compose`.
    # It must NOT issue the Kitty `a=d` (delete all placements) sequence —
    # otherwise the avatars rendered into the timeline before compose vanish
    # when the user returns.
    io = FakeTTY.new
    screen = Tempest::REPL::Screen.new(io: io, rows: 24)
    screen.enable
    io.truncate(0); io.rewind

    screen.suspend

    assert_includes io.string, "\e[r"
    refute_includes io.string, "\e_Ga=d"
    refute screen.enabled?
  end

  def test_resume_re_establishes_scrolling_region
    io = FakeTTY.new
    screen = Tempest::REPL::Screen.new(io: io, rows: 24)
    screen.enable
    screen.suspend
    io.truncate(0); io.rewind

    screen.resume

    assert_includes io.string, "\e[1;23r"
    assert_includes io.string, "\e[24;1H"
    assert screen.enabled?
  end

  def test_suspend_is_a_noop_when_screen_was_never_enabled
    io = StringIO.new # not a tty, so enable was a noop
    screen = Tempest::REPL::Screen.new(io: io, rows: 24)
    screen.suspend # must not crash or write anything

    assert_empty io.string
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

  # While `:compose` is running and $EDITOR owns the terminal, the Jetstream
  # thread is still alive and emitting events through Screen#puts. Those
  # writes must not leak onto the editor's screen — Screen swallows them
  # while suspended, then continues normally after resume.
  def test_puts_while_suspended_is_silent
    io = FakeTTY.new
    screen = Tempest::REPL::Screen.new(io: io, rows: 24, cols: 80)
    screen.enable
    screen.suspend
    io.truncate(0); io.rewind

    screen.puts "[13:26] @uzakin.bsky.social: liked @keireit.bsky.social's post"

    assert_empty io.string,
      "puts during suspend must not write to the terminal (editor owns it)"
  end

  def test_puts_after_resume_writes_normally_again
    io = FakeTTY.new
    screen = Tempest::REPL::Screen.new(io: io, rows: 24, cols: 80)
    screen.enable
    screen.suspend
    screen.resume
    io.truncate(0); io.rewind

    screen.puts "back online"

    assert_includes io.string, "back online"
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

  def test_puts_does_not_split_kitty_graphics_escape_sequences
    io = FakeTTY.new
    screen = Tempest::REPL::Screen.new(io: io, rows: 24, cols: 40)
    screen.enable
    io.truncate(0); io.rewind

    kitty_escape = "\e_Ga=T,f=100,r=1,c=2,C=1,m=0;#{"A" * 120}\e\\"
    screen.puts "#{kitty_escape} @alice.bsky.social: hi"

    graphics_escape = io.string[/\e_G.*?\e\\/m]
    refute_nil graphics_escape
    refute_includes graphics_escape, "\n",
      "screen wrapping must not inject line breaks inside Kitty graphics escapes"
  end

  # Posts containing a Kitty avatar must STILL be wrapped when their visible
  # width exceeds @cols. Previously wrap_to_cols bailed out (returned the
  # whole line untouched) whenever the line contained a Kitty escape because
  # Reline counted the base64 bytes toward visual width. The terminal then
  # auto-wrapped past the scrolling region, spilling text onto the prompt
  # row and dragging the avatar placement off-position relative to its post.
  def test_puts_wraps_long_post_with_kitty_avatar_into_multiple_chunks
    io = FakeTTY.new
    screen = Tempest::REPL::Screen.new(io: io, rows: 24, cols: 40)
    screen.enable
    io.truncate(0); io.rewind

    kitty_escape = "\e_Ga=T,f=100,r=1,c=2,C=1,m=0;#{"A" * 240}\e\\"
    # Visible payload alone is ~62 cells (10 + 2 + 20 + 30); should wrap into
    # at least two chunks at cols=40.
    long = "[$CR] [13:06] #{kitty_escape}  @takkanm.bsky.social: " +
      ("会社でF1の話をふられたのでマックスがアホかというはな")
    screen.puts long

    # Each chunk is preceded by move-to-last-row + clear-line; count them.
    move_clear_pairs = io.string.scan(/\e\[23;1H\r\e\[2K/).length
    assert_operator move_clear_pairs, :>=, 2,
      "long avatar-bearing post must be split into multiple scrolling-region writes"

    # The Kitty escape must remain intact (no newline inserted inside it).
    graphics_escape = io.string[/\e_G.*?\e\\/m]
    refute_nil graphics_escape
    refute_includes graphics_escape, "\n"
  end

  # A short line that contains an avatar (e.g. "[12:58] <icon>  @ason.as: hi")
  # must NOT be wrapped, even though the raw byte-length is enormous due to
  # the base64 image payload.
  def test_puts_does_not_wrap_short_post_with_kitty_avatar
    io = FakeTTY.new
    screen = Tempest::REPL::Screen.new(io: io, rows: 24, cols: 80)
    screen.enable
    io.truncate(0); io.rewind

    kitty_escape = "\e_Ga=T,f=100,r=1,c=2,C=1,m=0;#{"A" * 240}\e\\"
    screen.puts "[12:58] #{kitty_escape}  @ason.as: hi"

    assert_equal 1, io.string.scan(/\e\[23;1H/).length,
      "short avatar-bearing post fits in @cols and must remain a single chunk"
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

  # When the terminal is resized (SIGWINCH), the scrolling region we set at
  # enable-time becomes stale. Until we reissue DECSTBM with the new bottom row,
  # the prompt either wraps below the region or text spills onto the prompt
  # row, producing the duplicated `tempest> ` rows the user sees.
  def test_notify_resize_reissues_scrolling_region_with_new_rows_on_next_puts
    io = FakeTTY.new
    screen = Tempest::REPL::Screen.new(io: io, rows: 24, cols: 80)
    screen.enable
    io.truncate(0); io.rewind

    screen.notify_resize(rows: 30, cols: 80)
    screen.puts "after-resize"

    output = io.string
    # New scrolling region: rows 1..29, prompt parked on row 30.
    assert_includes output, "\e[1;29r"
    assert_includes output, "\e[30;1H"
    # The inserted line targets the new bottom-of-region row (29), not 23.
    assert_includes output, "\e[29;1H"
    refute_includes output, "\e[23;1H"
  end

  # cols matters too: stale @cols makes wrap_to_cols split wide lines into
  # too-many short chunks, causing two events' bytes to collide on the same
  # row in real terminals.
  def test_notify_resize_updates_cols_for_wrapping
    io = FakeTTY.new
    screen = Tempest::REPL::Screen.new(io: io, rows: 24, cols: 20)
    screen.enable
    io.truncate(0); io.rewind

    # cols=40 now fits the whole line; should land in a single chunk.
    screen.notify_resize(rows: 24, cols: 40)
    long = "0123456789ABCDEFGHIJKLMNOPQRSTUV" # 32 chars
    screen.puts long

    output = io.string
    assert_equal 1, output.scan(/\e\[23;1H/).length,
      "expected exactly one move-to-bottom because the line fits in 40 cols"
    assert_includes output, long
  end

  # If WINCH fires but the size didn't actually change (some terminals send
  # spurious notifications), don't reissue — saves a flicker and a redraw.
  def test_notify_resize_is_a_noop_when_dimensions_unchanged
    io = FakeTTY.new
    screen = Tempest::REPL::Screen.new(io: io, rows: 24, cols: 80)
    screen.enable
    io.truncate(0); io.rewind

    screen.notify_resize(rows: 24, cols: 80)
    screen.puts "hi"

    refute_includes io.string, "\e[1;23r",
      "must not reissue DECSTBM when nothing changed"
  end

  # A resize notification arriving before enable (CLI hasn't wired the prompt
  # yet) shouldn't crash and shouldn't emit anything — it should just update
  # the cached dims so enable picks them up.
  def test_notify_resize_before_enable_does_not_emit_sequences
    io = FakeTTY.new
    screen = Tempest::REPL::Screen.new(io: io, rows: 24, cols: 80)
    screen.notify_resize(rows: 30, cols: 100)

    assert_empty io.string
  end

  # enable() must install a SIGWINCH trap so terminal resizes drive
  # notify_resize without callers having to wire it. disable() restores the
  # previously-installed handler so we don't leak trap state across runs
  # (tests in the same process, daemonized child processes, etc.).
  def test_enable_installs_winch_trap_and_disable_restores_previous_handler
    skip "WINCH not supported on this platform" unless Signal.list.key?("WINCH")

    sentinel = ->(_signo) { :sentinel }
    previous = Signal.trap("WINCH", sentinel)

    begin
      io = FakeTTY.new
      screen = Tempest::REPL::Screen.new(io: io, rows: 24, cols: 80)
      screen.enable

      installed = Signal.trap("WINCH", sentinel) # read current and reset to sentinel
      refute_equal sentinel, installed,
        "enable should install its own WINCH handler"
      Signal.trap("WINCH", installed) # put screen's handler back

      screen.disable

      after_disable = Signal.trap("WINCH", "DEFAULT")
      assert_equal sentinel, after_disable,
        "disable must restore the pre-enable WINCH handler"
    ensure
      Signal.trap("WINCH", previous || "DEFAULT")
    end
  end
end
