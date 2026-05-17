require "json"

require_relative "../../tempest"
require_relative "../facet"

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
      :subject_uri,
      :facets,
    ) do
      def initialize(kind:, did:, time_us:, collection:, operation:, rkey:, cid:,
                     text:, created_at:, subject_uri: nil, facets: [])
        super
      end

      def post?
        collection == "app.bsky.feed.post"
      end

      def like?
        collection == "app.bsky.feed.like"
      end

      def repost?
        collection == "app.bsky.feed.repost"
      end

      def create?
        operation == :create
      end

      def at_uri
        "at://#{did}/#{collection}/#{rkey}"
      end
    end

    module Decoder
      module_function

      def decode(payload)
        message = JSON.parse(payload)
        return nil unless message["kind"] == "commit"

        commit = message["commit"] || {}
        record = commit["record"] || {}
        subject = record["subject"]

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
          subject_uri: subject.is_a?(Hash) ? subject["uri"] : nil,
          facets: Tempest::Facet.parse(record["facets"]),
        )
      rescue JSON::ParserError
        nil
      end
    end
  end
end
