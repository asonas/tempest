require "json"

require_relative "../../tempest"

module Tempest
  module Jetstream
    Event = Data.define(
      :kind,
      :did,
      :time_us,
      :collection,
      :operation,
      :rkey,
      :cid,
      :text,
      :created_at,
    ) do
      def post?
        collection == "app.bsky.feed.post"
      end

      def create?
        operation == :create
      end
    end

    module Decoder
      module_function

      def decode(payload)
        message = JSON.parse(payload)
        return nil unless message["kind"] == "commit"

        commit = message["commit"] || {}
        record = commit["record"] || {}

        Event.new(
          kind: :commit,
          did: message["did"],
          time_us: message["time_us"],
          collection: commit["collection"],
          operation: commit["operation"]&.to_sym,
          rkey: commit["rkey"],
          cid: commit["cid"],
          text: record["text"],
          created_at: record["createdAt"],
        )
      rescue JSON::ParserError
        nil
      end
    end
  end
end
