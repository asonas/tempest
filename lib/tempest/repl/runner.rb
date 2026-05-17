require "set"

require_relative "../../tempest"
require_relative "../timeline"
require_relative "../post"
require_relative "../jetstream/stream_manager"
require_relative "dispatcher"
require_relative "formatter"
require_relative "registry"

module Tempest
  module REPL
    class Runner
      PROMPT = "tempest> ".freeze

      HELP_TEXT = <<~HELP
        Available commands:
          :timeline       Fetch and print the home timeline
          :stream on|off  Toggle the Jetstream live feed
          :open $XX|$LX   Open the post or URL with the given id in the browser
          :fav $XX        Like the post with id $XX
          :relogin        Re-authenticate when the cached session is dead
          :help           Show this help
          :quit           Exit tempest (or Ctrl-D)

          $XX <text>      Reply to the post with id $XX

        Any other input is sent as a new post.
      HELP

      DEFAULT_OPENER = ->(url) { system("open", url) }

      RELOGIN_HINT = "type :relogin to re-authenticate".freeze

      def initialize(session:, client:, input:, output:, dispatcher: Dispatcher.new,
                     stream_manager: nil, handle_resolver: nil, stream_output: nil,
                     timeline_store: nil, registry: Registry.new, opener: DEFAULT_OPENER,
                     avatar_store: nil, reauth: nil)
        @session = session
        @client = client
        @input = input
        @output = output
        @stream_output = stream_output || output
        @dispatcher = dispatcher
        @stream_manager = stream_manager
        @handle_resolver = handle_resolver
        @timeline_store = timeline_store
        @registry = registry
        @opener = opener
        @avatar_store = avatar_store
        @reauth = reauth
        # URIs already printed via bootstrap_timeline or backfill_timeline.
        # Jetstream's cursor-replay can re-emit those same posts on startup
        # (the persisted cursor is older than the getTimeline window), so the
        # stream handler skips post events whose URI is in this set.
        @displayed_post_uris = Set.new
      end

      def bootstrap_timeline
        return unless @timeline_store

        cached = @timeline_store.load
        cached_posts = cached ? Array(cached[:posts]) : []
        cached_posts.each { |post| print_post(post) }

        cached_uris = cached_posts.map(&:uri).to_set
        begin
          fetched = Timeline.fetch(@client)
        rescue Tempest::Error => e
          @output.puts "-- timeline fetch failed: #{e.message}"
          return
        end

        new_posts = fetched.reject { |post| cached_uris.include?(post.uri) }
        new_posts.reverse_each { |post| print_post(post) }

        merged = cached_posts + new_posts.reverse
        @timeline_store.save(posts: merged)
      end

      def auto_start_stream
        return unless @stream_manager
        return if @stream_manager.running?

        @stream_manager.start { |event| handle_stream_event(event) }
      end

      def run
        loop do
          line = read_line
          command = @dispatcher.dispatch(line)

          case command.name
          when :quit
            @stream_manager&.stop
            @output.puts "bye."
            break
          when :noop
            next
          when :help
            @output.puts HELP_TEXT
          when :timeline
            handle_timeline
          when :stream
            handle_stream(command.args.first)
          when :post
            handle_post(command.args.first)
          when :reply
            handle_reply(command.args[0], command.args[1])
          when :open
            handle_open(command.args.first)
          when :fav
            handle_fav(command.args.first)
          when :relogin
            handle_relogin
          when :unknown
            @output.puts "unknown command: :#{command.args.first}"
          end
        end
      end

      private

      def read_line
        @input.readline(PROMPT)
      rescue Interrupt
        nil
      end

      def handle_timeline
        posts = Timeline.fetch(@client)
        if posts.empty?
          @output.puts "(empty timeline)"
        else
          posts.reverse_each { |post| @output.puts Formatter.post_line(post, registry: @registry, avatar_store: @avatar_store) }
          @timeline_store&.save(posts: posts.reverse)
        end
      rescue Tempest::Error => e
        @output.puts "error: #{e.message}"
      end

      def handle_post(text)
        response = Post.create(@client, did: @session.did, text: text)
        @output.puts "posted: #{response["uri"]}"
      rescue Tempest::AuthenticationError => e
        @output.puts "error: #{e.message} (#{RELOGIN_HINT})"
      rescue Tempest::Error => e
        @output.puts "error: #{e.message}"
      end

      def handle_relogin
        if @reauth.nil?
          @output.puts "relogin is not available in this session"
          return
        end

        new_session = @reauth.call
        @session.replace_with!(new_session)
        @output.puts "signed in as @#{@session.handle}"
      rescue Tempest::Error => e
        @output.puts "relogin failed: #{e.message}"
      end

      def handle_reply(var, body)
        target = @registry.find_post(var)
        if target.nil?
          @output.puts "unknown id: #{var}"
          return
        end
        body = body.to_s.strip
        if body.empty?
          @output.puts "usage: $XX <text>"
          return
        end
        response = Post.create(
          @client,
          did: @session.did,
          text: body,
          reply: { uri: reply_uri_for(target), cid: target.cid },
        )
        @output.puts "posted: #{response["uri"]}"
      rescue Tempest::AuthenticationError => e
        @output.puts "error: #{e.message} (#{RELOGIN_HINT})"
      rescue Tempest::Error => e
        @output.puts "error: #{e.message}"
      end

      def handle_fav(var)
        if var.nil? || var.empty?
          @output.puts "usage: :fav $XX"
          return
        end
        target = @registry.find_post(var)
        if target.nil?
          @output.puts "unknown id: #{var}"
          return
        end
        response = Post.like(
          @client,
          did: @session.did,
          subject_uri: reply_uri_for(target),
          subject_cid: target.cid,
        )
        @output.puts "liked: #{response["uri"]}"
      rescue Tempest::AuthenticationError => e
        @output.puts "error: #{e.message} (#{RELOGIN_HINT})"
      rescue Tempest::Error => e
        @output.puts "error: #{e.message}"
      end

      def handle_open(var)
        if var.nil? || var.empty?
          @output.puts "usage: :open $XX or $LX"
          return
        end

        if (post = @registry.find_post(var))
          url = bsky_post_url(post)
        else
          url = @registry.find_url(var)
        end

        if url.nil?
          @output.puts "unknown id: #{var}"
          return
        end
        ok = @opener.call(url)
        @output.puts "error: failed to open #{url}" unless ok
      end

      def reply_uri_for(target)
        target.respond_to?(:uri) && target.uri ? target.uri : target.at_uri
      end

      # bsky.app accepts both handles and DIDs in the profile path. Prefer the
      # handle when we have it (human-readable URLs are nicer for sharing or
      # for the user to glance at), but fall back to the DID for posts that
      # arrived through Jetstream where only the DID is known.
      def bsky_post_url(target)
        at_uri = reply_uri_for(target)
        match = at_uri.match(%r{\Aat://([^/]+)/app\.bsky\.feed\.post/(.+)\z})
        return nil unless match

        did = match[1]
        rkey = match[2]
        handle = target.respond_to?(:handle) ? target.handle : nil
        profile = handle && !handle.empty? ? handle : did
        "https://bsky.app/profile/#{profile}/post/#{rkey}"
      end

      def handle_stream(arg)
        if @stream_manager.nil?
          @output.puts "stream is not available in this session"
          return
        end

        case arg
        when nil, "on"
          if @stream_manager.running?
            @output.puts "stream is already on"
          else
            @stream_manager.start { |event| handle_stream_event(event) }
            @output.puts "stream on"
          end
        when "off"
          @stream_manager.stop
          @output.puts "stream off"
        else
          @output.puts "usage: :stream on|off"
        end
      end

      def handle_stream_event(event)
        case event
        when Tempest::Jetstream::StreamError
          @stream_output.puts "stream error: #{event.cause.class}: #{event.cause.message}"
        when Tempest::Jetstream::StreamStatus
          @stream_output.puts Formatter.status_line(event)
          backfill_timeline if event.state == :gapped
        else
          return unless event.respond_to?(:create?) && event.create?
          return unless event.post? || event.like? || event.repost?
          return if event.post? && @displayed_post_uris.include?(event.at_uri)

          @stream_output.puts Formatter.event_line(event, registry: @registry, resolver: @handle_resolver, avatar_store: @avatar_store)
          @displayed_post_uris << event.at_uri if event.post?
        end
      end

      def backfill_timeline
        posts = Timeline.fetch(@client)
        posts.reverse_each do |post|
          next if @displayed_post_uris.include?(post.uri)
          print_post(post, output: @stream_output)
        end
      rescue Tempest::Error => e
        @stream_output.puts "-- timeline backfill failed: #{e.message}"
      end

      def print_post(post, output: @output)
        output.puts Formatter.post_line(post, registry: @registry, avatar_store: @avatar_store)
        @displayed_post_uris << post.uri
      end
    end
  end
end
