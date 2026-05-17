require_relative "../../tempest"
require_relative "../repl/formatter"

module Tempest
  module Output
    class LineWriter
      def initialize(io)
        @io = io
      end

      def write_posts(posts)
        posts.each { |p| @io.puts Tempest::REPL::Formatter.post_line(p) }
      end

      def write_error(message, code: nil, details: nil)
        @io.puts "error: #{message}"
      end
    end
  end
end
