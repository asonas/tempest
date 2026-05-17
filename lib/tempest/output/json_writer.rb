require "json"

module Tempest
  module Output
    class JsonWriter
      def initialize(io)
        @io = io
      end

      def write_posts(views)
        views.each { |v| @io.puts JSON.generate(v) }
      end

      def write_error(message, code:, details: nil)
        payload = { "error" => message, "code" => code }
        payload["details"] = details unless details.nil?
        @io.puts JSON.generate(payload)
      end

      def write_raw(payload)
        @io.puts JSON.pretty_generate(payload)
      end
    end
  end
end
