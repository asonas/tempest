require_relative "../tempest"
require_relative "facet"

module Tempest
  Post = Data.define(:uri, :cid, :handle, :display_name, :text, :created_at, :facets) do
    def initialize(uri:, cid:, handle:, display_name:, text:, created_at:, facets: [])
      super
    end

    def self.from_feed_view(post)
      post = post || {}
      author = post["author"] || {}
      record = post["record"] || {}
      new(
        uri: post["uri"],
        cid: post["cid"],
        handle: author["handle"],
        display_name: author["displayName"],
        text: record["text"],
        created_at: record["createdAt"],
        facets: Facet.parse(record["facets"]),
      )
    end

    # Compose a record for com.atproto.repo.createRecord (app.bsky.feed.post).
    # When `reply` is provided, both root and parent are set to the same
    # target. This is correct for top-level replies and a known v1 trade-off
    # for replies deeper in a thread (AppView will nest the reply under
    # `parent` instead of the original conversation root).
    def self.create(client, did:, text:, reply: nil,
                    created_at: Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ"))
      record = {
        "$type" => "app.bsky.feed.post",
        "text" => text,
        "createdAt" => created_at,
      }
      if reply
        ref = { "uri" => reply[:uri], "cid" => reply[:cid] }
        record["reply"] = { "root" => ref, "parent" => ref }
      end

      client.post(
        "com.atproto.repo.createRecord",
        body: {
          repo: did,
          collection: "app.bsky.feed.post",
          record: record,
        },
      )
    end
  end
end
