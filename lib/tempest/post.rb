require_relative "../tempest"

module Tempest
  Post = Data.define(:uri, :cid, :handle, :display_name, :text, :created_at) do
    def self.from_feed_view(post)
      author = post["author"] || {}
      record = post["record"] || {}
      new(
        uri: post["uri"],
        cid: post["cid"],
        handle: author["handle"],
        display_name: author["displayName"],
        text: record["text"],
        created_at: record["createdAt"],
      )
    end

    # Compose a record for com.atproto.repo.createRecord (app.bsky.feed.post).
    def self.create(client, did:, text:, created_at: Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ"))
      client.post(
        "com.atproto.repo.createRecord",
        body: {
          repo: did,
          collection: "app.bsky.feed.post",
          record: { "$type" => "app.bsky.feed.post", "text" => text, "createdAt" => created_at },
        },
      )
    end
  end
end
