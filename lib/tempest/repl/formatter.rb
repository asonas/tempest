require_relative "../../tempest"

module Tempest
  module REPL
    module Formatter
      module_function

      def post_line(post)
        text = post.text.to_s.gsub(/\s*\n\s*/, " ")
        "@#{post.handle}: #{text}"
      end

      # Jetstream events don't carry the author handle, only the DID. Until we
      # add DID-to-handle resolution we render the DID and rely on the operator
      # to interpret it.
      def event_line(event)
        return "[stream] <#{event.did}> deleted #{event.collection}/#{event.rkey}" if event.operation == :delete

        text = event.text.to_s.gsub(/\s*\n\s*/, " ")
        "[stream] <#{event.did}> #{text}"
      end
    end
  end
end
