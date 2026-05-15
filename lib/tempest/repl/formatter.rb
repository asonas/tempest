require_relative "../../tempest"

module Tempest
  module REPL
    module Formatter
      module_function

      def post_line(post)
        text = post.text.to_s.gsub(/\s*\n\s*/, " ")
        "@#{post.handle}: #{text}"
      end
    end
  end
end
