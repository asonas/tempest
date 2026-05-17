require "time"
require "uri"

require_relative "../../tempest"

module Tempest
  module REPL
    # Renders posts and Jetstream events as terminal lines, earthquake-style:
    #   [$AA] [HH:MM] @handle: text
    # The leading [$AA] is only emitted when a Registry is supplied (and the
    # event is something that can be replied to — a post, not a delete or a
    # like/repost record). URLs found in the body are annotated inline with
    # their own ($LA) ids when a registry is supplied.
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

      def post_line(post, registry: nil)
        var = registry&.assign_post(post)
        facets = post.respond_to?(:facets) ? post.facets : nil
        body = annotate_urls(squeeze(post.text), registry, facets: facets)
        body = decorate_body(body)
        compose(var, format_time(post.created_at), post.handle, nil, body)
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

      def event_line(event, registry: nil, resolver: nil)
        handle = resolver&.resolve(event.did)
        if event.operation == :delete
          body = "(deleted #{event.collection}/#{event.rkey})"
          var = nil
        elsif event.respond_to?(:like?) && event.like?
          body = "liked #{subject_owner_label(event.subject_uri, resolver)}"
          var = nil
        elsif event.respond_to?(:repost?) && event.repost?
          body = "reposted #{subject_owner_label(event.subject_uri, resolver)}"
          var = nil
        else
          facets = event.respond_to?(:facets) ? event.facets : nil
          body = annotate_urls(squeeze(event.text), registry, facets: facets)
          body = decorate_body(body)
          var = registry&.assign_post(event)
        end
        compose(var, format_time(event.created_at), handle, event.did, body)
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

      def annotate_urls(text, registry, facets: nil)
        return text unless registry
        text = text.to_s
        if facets && !facets.empty?
          return annotate_urls_with_facets(text, registry, facets)
        end

        urls = URI.extract(text, ["http", "https"]).uniq
        urls.each do |url|
          var = registry.assign_url(url)
          text = text.sub(url, "#{url} (#{var})")
        end
        text
      end

      def annotate_urls_with_facets(text, registry, facets)
        text = text.dup.force_encoding(Encoding::UTF_8)
        bytesize = text.bytesize
        valid = facets
          .select { |f| f.byte_start.is_a?(Integer) && f.byte_end.is_a?(Integer) }
          .select { |f| f.byte_start >= 0 && f.byte_end <= bytesize && f.byte_start < f.byte_end }
          .sort_by(&:byte_start)

        # Assign vars in reading order so earlier facets get earlier ids.
        replacements = valid.map do |facet|
          var = registry.assign_url(facet.uri)
          domain = host_of(facet.uri) || facet.uri
          [facet, "[#{domain} #{var}]"]
        end

        # Apply substitutions in reverse byte order so earlier ranges remain valid.
        replacements.reverse_each do |facet, replacement|
          head = text.byteslice(0, facet.byte_start) || ""
          tail = text.byteslice(facet.byte_end, text.bytesize - facet.byte_end) || ""
          text = (head + replacement + tail).force_encoding(Encoding::UTF_8)
        end
        text
      end

      def host_of(uri)
        parsed = URI.parse(uri)
        host = parsed.host
        host && !host.empty? ? host : nil
      rescue URI::InvalidURIError
        nil
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

      def compose(var, time, handle, did, text)
        prefix = ""
        prefix += id_label(var) if var
        prefix += bracket(time) if time
        identity = handle ? handle_label(handle) : did_label(did)
        "#{prefix}#{identity}: #{text}"
      end

      def bracket(time)
        Formatter.color ? "#{CYAN}[#{time}]#{RESET} " : "[#{time}] "
      end

      def id_label(var)
        Formatter.color ? "#{DIM}[#{var}]#{RESET} " : "[#{var}] "
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
