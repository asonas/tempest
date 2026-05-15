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
      HASHTAG_BLUE = "\e[38;5;110m".freeze

      HASHTAG_PATTERN = /#[[:alnum:]_]+/.freeze
      URL_PATTERN = %r{https?://[^\s]+}.freeze
      DECORATE_PATTERN = Regexp.union(URL_PATTERN, HASHTAG_PATTERN).freeze

      class << self
        attr_accessor :color
      end
      self.color = false

      module_function

      def post_line(post)
        compose(format_time(post.created_at), post.handle, nil, decorate_body(squeeze(post.text)))
      end

      def decorate_body(text)
        return text unless Formatter.color
        return text if text.nil? || text.empty?

        text.gsub(DECORATE_PATTERN) do |match|
          color = match.start_with?("http") ? DIM : HASHTAG_BLUE
          "#{color}#{match}#{RESET}"
        end
      end

      def status_line(status)
        body = case status.state
        when :disconnected
          status.reason == :error && status.error ? "disconnected: #{status.error.message}" : "disconnected"
        when :reconnecting
          "reconnecting..."
        when :live
          "live"
        when :gapped
          "fetching timeline (offline since #{format_status_time(status.since)})"
        else
          status.state.to_s
        end
        Formatter.color ? "#{DIM}-- #{body}#{RESET}" : "-- #{body}"
      end

      def format_status_time(time)
        time.respond_to?(:localtime) ? time.localtime.strftime("%H:%M") : time.to_s
      end

      def event_line(event, resolver: nil)
        handle = resolver&.resolve(event.did)
        body = if event.operation == :delete
          "(deleted #{event.collection}/#{event.rkey})"
        elsif event.respond_to?(:like?) && event.like?
          "liked #{subject_owner_label(event.subject_uri, resolver)}"
        elsif event.respond_to?(:repost?) && event.repost?
          "reposted #{subject_owner_label(event.subject_uri, resolver)}"
        else
          decorate_body(squeeze(event.text))
        end
        compose(format_time(event.created_at), handle, event.did, body)
      end

      def subject_owner_label(subject_uri, resolver)
        did = subject_did(subject_uri)
        return "a post" unless did

        handle = resolver&.resolve(did)
        owner = handle ? handle_label(handle) : did_label(did)
        "#{owner}'s post"
      end

      def subject_did(subject_uri)
        return nil if subject_uri.nil? || subject_uri.empty?
        match = subject_uri.match(%r{\Aat://([^/]+)/})
        match && match[1]
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
