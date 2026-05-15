require_relative "../../tempest"
require_relative "../timeline"
require_relative "../post"
require_relative "dispatcher"
require_relative "formatter"

module Tempest
  module REPL
    class Runner
      PROMPT = "tempest> ".freeze

      HELP_TEXT = <<~HELP
        Available commands:
          :timeline   Fetch and print the home timeline
          :help       Show this help
          :quit       Exit tempest (or Ctrl-D)

        Any other input is sent as a new post.
      HELP

      def initialize(session:, client:, input:, output:, dispatcher: Dispatcher.new)
        @session = session
        @client = client
        @input = input
        @output = output
        @dispatcher = dispatcher
      end

      def run
        loop do
          line = read_line
          command = @dispatcher.dispatch(line)

          case command.name
          when :quit
            @output.puts "bye."
            break
          when :noop
            next
          when :help
            @output.puts HELP_TEXT
          when :timeline
            handle_timeline
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
    end
  end
end
