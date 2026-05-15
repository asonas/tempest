require "time"

require_relative "../../tempest"

module Tempest
  module REPL
    # Renders posts and Jetstream events as terminal lines, earthquake-style:
    #   [HH:MM] @handle: text
    # ANSI colors are emitted only when Formatter.color is true (set by the
    # CLI when stdout is a TTY); tests run with color disabled.
    module Formatter
      RESET = "\e[0m".freeze
      CYAN = "\e[36m".freeze
      GREEN = "\e[32m".freeze
      DIM = "\e[2m".freeze

      class << self
        attr_accessor :color
      end
      self.color = false

      module_function

      def post_line(post)
        compose(format_time(post.created_at), post.handle, nil, squeeze(post.text))
      end

      def event_line(event, resolver: nil)
        handle = resolver&.resolve(event.did)
        body = if event.operation == :delete
          "(deleted #{event.collection}/#{event.rkey})"
        else
          squeeze(event.text)
        end
        compose(format_time(event.created_at), handle, event.did, body)
      end

      def squeeze(text)
        text.to_s.gsub(/\s*\n\s*/, " ")
      end

      def format_time(iso)
        return nil if iso.nil? || iso.empty?
        Time.iso8601(iso).localtime.strftime("%H:%M")
      rescue ArgumentError
        nil
      end

      def compose(time, handle, did, text)
        prefix = time ? bracket(time) : ""
        identity = handle ? handle_label(handle) : did_label(did)
        "#{prefix}#{identity}: #{text}"
      end

      def bracket(time)
        Formatter.color ? "#{CYAN}[#{time}]#{RESET} " : "[#{time}] "
      end

      def handle_label(handle)
        Formatter.color ? "#{GREEN}@#{handle}#{RESET}" : "@#{handle}"
      end

      def did_label(did)
        Formatter.color ? "#{DIM}<#{did}>#{RESET}" : "<#{did}>"
      end
    end
  end
end
