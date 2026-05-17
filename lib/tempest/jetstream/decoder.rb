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
      :reply_parent_uri,
    ) do
      def initialize(kind:, did:, time_us:, collection:, operation:, rkey:, cid:,
                     text:, created_at:, subject_uri: nil, facets: [],
                     reply_parent_uri: nil)
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
        reply = record["reply"]
        reply_parent = reply.is_a?(Hash) ? reply["parent"] : nil

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
          reply_parent_uri: reply_parent.is_a?(Hash) ? reply_parent["uri"] : nil,
        )
      rescue JSON::ParserError
        nil
      end
    end
  end
end
