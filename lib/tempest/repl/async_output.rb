require_relative "../../tempest"

module Tempest
  module REPL
    # Wraps an IO so writes from background threads (Jetstream events) don't
    # smash Reline's prompt. Each puts clears the current terminal line and
    # then asks Reline to re-render the prompt and the user's in-flight input
    # buffer. Best-effort: if Reline isn't loaded or the rerender hook isn't
    # available, we just degrade to a normal write.
    class AsyncOutput
      def initialize(io)
        @io = io
      end

      def puts(*lines)
        if lines.empty?
          @io.print "\r\e[2K"
          @io.puts
        else
          lines.each do |line|
            @io.print "\r\e[2K"
            @io.puts line
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

      def rerender_prompt
        return unless defined?(Reline)
        Reline.line_editor&.rerender
      rescue StandardError
        # Reline's private APIs may move; never let a redraw failure surface.
      end
    end
  end
end
