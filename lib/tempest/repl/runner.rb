require_relative "../../tempest"
require_relative "../timeline"
require_relative "../post"
require_relative "../jetstream/stream_manager"
require_relative "dispatcher"
require_relative "formatter"

module Tempest
  module REPL
    class Runner
      PROMPT = "tempest> ".freeze

      HELP_TEXT = <<~HELP
        Available commands:
          :timeline       Fetch and print the home timeline
          :stream on|off  Toggle the Jetstream live feed
          :help           Show this help
          :quit           Exit tempest (or Ctrl-D)

        Any other input is sent as a new post.
      HELP

      def initialize(session:, client:, input:, output:, dispatcher: Dispatcher.new,
                     stream_manager: nil, handle_resolver: nil, stream_output: nil)
        @session = session
        @client = client
        @input = input
        @output = output
        @stream_output = stream_output || output
        @dispatcher = dispatcher
        @stream_manager = stream_manager
        @handle_resolver = handle_resolver
      end

      # Starts the Jetstream feed without printing a status line. Used at boot
      # so the REPL drops straight into a live timeline (earthquake-style).
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
          posts.reverse_each { |post| @output.puts Formatter.post_line(post) }
        end
      rescue Tempest::Error => e
        @output.puts "error: #{e.message}"
      end

      def handle_post(text)
        response = Post.create(@client, did: @session.did, text: text)
        @output.puts "posted: #{response["uri"]}"
      rescue Tempest::Error => e
        @output.puts "error: #{e.message}"
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
        if event.is_a?(Tempest::Jetstream::StreamError)
          @stream_output.puts "stream error: #{event.cause.class}: #{event.cause.message}"
          return
        end
        return unless event.respond_to?(:post?) && event.post? && event.create?

        @stream_output.puts Formatter.event_line(event, resolver: @handle_resolver)
      end
    end
  end
end
