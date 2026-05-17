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
      end

      def disable
        return unless @enabled
        @io.print "\e_Ga=d,q=2\e\\"
        @io.print "\e[r"
        @io.flush if @io.respond_to?(:flush)
        @enabled = false
      end

      def enabled?
        @enabled
      end

      def puts(*lines)
        @mutex.synchronize do
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

      def wrap_to_cols(line)
        return [line] unless @cols && @cols.positive?
        return [line] if line.include?("\e_G")
        return [line] if Reline::Unicode.calculate_width(line, true) <= @cols

        chunks, _ = Reline::Unicode.split_by_width(line, @cols)
        chunks.compact.reject(&:empty?)
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
