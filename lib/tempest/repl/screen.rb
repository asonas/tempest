require "reline"
require_relative "../../tempest"

module Tempest
  module REPL
    # Implements the earthquake-style split layout: the bottom row holds the
    # tempest> prompt, while the rest of the terminal scrolls timeline lines
    # in from below. Built on the DECSTBM (top/bottom margin) escape sequence
    # so we don't need a full curses screen.
    #
    # Sequences used:
    #   CSI top;bottom r  set scrolling region
    #   CSI r             reset scrolling region (full screen)
    #   CSI row;col H     move cursor
    #   ESC 7 / ESC 8     save/restore cursor (DECSC/DECRC)
    class Screen
      def initialize(io:, rows: nil, cols: nil)
        @io = io
        @rows = rows
        @cols = cols
        @enabled = false
        @mutex = Mutex.new
        @pending_resize = nil
      end

      def enable
        return unless @io.respond_to?(:tty?) && @io.tty?
        rows = @rows || detect_rows
        return unless rows && rows >= 4

        @rows = rows
        @cols ||= detect_cols
        @io.print "\e[1;#{rows - 1}r"   # scrolling region: rows 1..rows-1
        @io.print "\e[#{rows};1H"        # park cursor on the final row (prompt)
        @io.flush if @io.respond_to?(:flush)
        @enabled = true
        install_resize_trap
      end

      def disable
        return unless @enabled
        uninstall_resize_trap
        @io.print "\e_Ga=d,q=2\e\\"
        @io.print "\e[r"
        @io.flush if @io.respond_to?(:flush)
        @enabled = false
      end

      # Transient teardown for handing the terminal off to a subprocess (e.g.
      # $EDITOR via `:compose`). Unlike `disable`, this does NOT issue the
      # Kitty graphics delete sequence — terminals that support the Kitty
      # protocol keep image placements in the main screen buffer even while
      # the editor draws on the alternate buffer, so suspending without
      # deleting lets the avatars re-appear automatically when the editor
      # exits. Pair with `resume` to re-establish the scrolling region.
      def suspend
        return unless @enabled
        uninstall_resize_trap
        @io.print "\e[r"
        @io.flush if @io.respond_to?(:flush)
        @enabled = false
      end

      def resume
        return if @enabled
        enable
      end

      def enabled?
        @enabled
      end

      # SIGWINCH hook. Trap handlers in Ruby are restricted (can't reliably
      # acquire mutexes or drive Reline), so we only stash the new dimensions
      # here and apply them on the next mutex-protected write. If rows/cols
      # are omitted (the production path), they're read from IO.console at
      # apply time so coalesced WINCHes still pick up the latest size.
      def notify_resize(rows: nil, cols: nil)
        @pending_resize = { rows: rows, cols: cols }
      end

      def puts(*lines)
        @mutex.synchronize do
          apply_pending_resize
          if @enabled
            flat = lines.empty? ? [""] : lines.flat_map { |l| l.to_s.split("\n") }
            flat.each { |line| insert_above_prompt(line) }
          else
            # Best-effort write that doesn't shred the prompt when we don't have
            # a scrolling region in place. Reline rerender is invoked by
            # AsyncOutput; Screen itself stays neutral here.
            (lines.empty? ? [""] : lines).each do |line|
              @io.print "\r\e[2K"
              @io.puts line
            end
            @io.flush if @io.respond_to?(:flush)
          end
        end
        rerender_prompt
      end

      def print(*args)
        @io.print(*args)
      end

      def write(*args)
        @io.write(*args)
      end

      def flush
        @io.flush if @io.respond_to?(:flush)
      end

      def tty?
        @io.respond_to?(:tty?) ? @io.tty? : false
      end

      def respond_to_missing?(name, include_private = false)
        @io.respond_to?(name, include_private)
      end

      def method_missing(name, *args, **kwargs, &block)
        @io.send(name, *args, **kwargs, &block)
      end

      private

      # Caller must hold @mutex. Re-issues DECSTBM and re-parks the cursor on
      # the new prompt row when winsize actually changed; cheap no-op when it
      # didn't (some terminals send spurious WINCHes on focus changes).
      def apply_pending_resize
        pending = @pending_resize
        return unless pending
        @pending_resize = nil

        new_rows = pending[:rows] || detect_rows
        new_cols = pending[:cols] || detect_cols
        return unless new_rows && new_rows >= 4
        return if new_rows == @rows && new_cols == @cols

        @rows = new_rows
        @cols = new_cols
        return unless @enabled

        @io.print "\e[1;#{@rows - 1}r"
        @io.print "\e[#{@rows};1H"
        @io.flush if @io.respond_to?(:flush)
      end

      # Install a SIGWINCH trap that only flips a flag. Ruby's trap context
      # forbids most blocking work (mutexes, IO that might re-enter Reline),
      # so the actual DECSTBM reissue happens later when puts/print pick up
      # the pending resize. The previous handler is saved so disable can
      # restore it cleanly.
      def install_resize_trap
        return unless Signal.list.key?("WINCH")
        screen = self
        @previous_winch_trap = Signal.trap("WINCH") { screen.notify_resize }
      rescue ArgumentError
        # Some embedded Rubies refuse to trap WINCH; nothing to do.
        @previous_winch_trap = nil
      end

      def uninstall_resize_trap
        return unless Signal.list.key?("WINCH")
        Signal.trap("WINCH", @previous_winch_trap || "DEFAULT")
        @previous_winch_trap = nil
      rescue ArgumentError
        @previous_winch_trap = nil
      end

      def detect_rows
        return nil unless defined?(IO) && IO.respond_to?(:console)
        console = IO.console
        return nil unless console
        rows, _cols = console.winsize
        rows
      rescue StandardError
        nil
      end

      def detect_cols
        return nil unless defined?(IO) && IO.respond_to?(:console)
        console = IO.console
        return nil unless console
        _rows, cols = console.winsize
        cols
      rescue StandardError
        nil
      end

      # The terminal would otherwise wrap a line that overflows `@cols` past
      # the bottom of the scrolling region and into the prompt row. Split the
      # line into width-bounded chunks so each one fits and scrolls the region
      # cleanly.
      def insert_above_prompt(line)
        chunks = wrap_to_cols(line)
        bottom_of_region = @rows - 1
        @io.print "\e7"                       # save cursor
        chunks.each do |chunk|
          @io.print "\e[#{bottom_of_region};1H" # move to last row of scrolling region
          @io.print "\r\e[2K"                   # clear that row first
          @io.print "#{chunk}\n"                # write chunk; \n scrolls region up by 1
        end
        @io.print "\e8"                       # restore cursor
        @io.flush if @io.respond_to?(:flush)
      end

      # Kitty graphics escape: `\e_G<controls>;<data>\e\\`. A single avatar
      # may be transmitted as multiple consecutive `\e_G..\e\\` chunks (each
      # capped at CHUNK_BYTES) when the PNG is large, but each chunk is still
      # an atomic terminal command that must not be broken by a newline.
      KITTY_ESCAPE = /\e_G[^\e]*?\e\\/m.freeze
      private_constant :KITTY_ESCAPE

      def wrap_to_cols(line)
        return [line] unless @cols && @cols.positive?
        return [line] if visible_width(line) <= @cols

        # Tokenize the line into kitty-escape blocks and plain text. Plain
        # text is split by display width; escape blocks travel intact and
        # contribute 0 cells to the running width (their visual footprint —
        # 2 cells per avatar in our usage — is reserved by literal spaces in
        # the surrounding text, see Formatter#compose).
        parts = line.split(/(#{KITTY_ESCAPE})/)
        chunks = []
        current = String.new
        current_width = 0

        parts.each do |part|
          next if part.empty?
          if part.start_with?("\e_G")
            current << part
            next
          end

          remaining = part
          until remaining.empty?
            available = @cols - current_width
            if available <= 0
              chunks << current
              current = String.new
              current_width = 0
              available = @cols
            end

            head, tail = take_by_display_width(remaining, available)
            if head.empty?
              # Next grapheme is wider than the remaining cells — flush and retry.
              chunks << current unless current.empty?
              current = String.new
              current_width = 0
              next
            end

            current << head
            current_width += Reline::Unicode.calculate_width(head, true)
            remaining = tail
          end
        end

        chunks << current unless current.empty?
        chunks
      end

      # Returns [head, tail] such that head's display width is <= max_width and
      # head + tail == str. Walks graphemes so we don't split a CJK character
      # across chunks.
      def take_by_display_width(str, max_width)
        head = String.new
        width = 0
        str.each_grapheme_cluster do |g|
          w = Reline::Unicode.calculate_width(g, true)
          break if width + w > max_width
          head << g
          width += w
        end
        [head, str.byteslice(head.bytesize, str.bytesize - head.bytesize) || ""]
      end

      def visible_width(line)
        stripped = line.gsub(KITTY_ESCAPE, "")
        Reline::Unicode.calculate_width(stripped, true)
      end

      def rerender_prompt
        return unless defined?(Reline)
        Reline.line_editor&.rerender
      rescue StandardError
        # never let a redraw failure surface
      end
    end
  end
end
