require_relative "../tempest"
require_relative "facet"

module Tempest
  Post = Data.define(:uri, :cid, :handle, :display_name, :text, :created_at, :facets, :reply_parent_uri) do
    def initialize(uri:, cid:, handle:, display_name:, text:, created_at:,
                   facets: [], reply_parent_uri: nil)
      super
    end

    def self.from_feed_view(post)
      post = post || {}
      author = post["author"] || {}
      record = post["record"] || {}
      reply = record["reply"]
      reply_parent = reply.is_a?(Hash) ? reply["parent"] : nil
      new(
        uri: post["uri"],
        cid: post["cid"],
        handle: author["handle"],
        display_name: author["displayName"],
        text: record["text"],
        created_at: record["createdAt"],
        facets: Facet.parse(record["facets"]),
        reply_parent_uri: reply_parent.is_a?(Hash) ? reply_parent["uri"] : nil,
      )
    end

    # Compose a record for com.atproto.repo.createRecord (app.bsky.feed.post).
    # When `reply` is provided, both root and parent are set to the same
    # target. This is correct for top-level replies and a known v1 trade-off
    # for replies deeper in a thread (AppView will nest the reply under
    # `parent` instead of the original conversation root).
    def self.create(client, did:, text:, reply: nil, langs: nil,
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

      record["langs"] = langs if langs && !langs.empty?

      link_facets = detect_link_facets(text)
      record["facets"] = link_facets unless link_facets.empty?

      client.post(
        "com.atproto.repo.createRecord",
        body: {
          repo: did,
          collection: "app.bsky.feed.post",
          record: record,
        },
      )
    end

    # Scans `text` for bare URLs and builds AT Protocol link facets pointing
    # at each match. Without this, the AppView treats URLs as plain text and
    # does not render them as clickable links.
    def self.detect_link_facets(text)
      return [] if text.nil? || text.empty?

      bytes = text.b
      facets = []
      pos = 0
      while (match = /https?:\/\/\S+/n.match(bytes, pos))
        byte_start = match.begin(0)
        byte_end = match.end(0)
        uri = match[0].dup.force_encoding(Encoding::UTF_8)
        facets << {
          "index" => { "byteStart" => byte_start, "byteEnd" => byte_end },
          "features" => [
            { "$type" => "app.bsky.richtext.facet#link", "uri" => uri },
          ],
        }
        pos = byte_end
      end
      facets
    end
  end
end
