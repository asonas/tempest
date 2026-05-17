require_relative "../tempest"

module Tempest
  module PostView
    EMBED_KINDS = {
      "app.bsky.embed.images"   => :images,
      "app.bsky.embed.record"   => :record,
      "app.bsky.embed.external" => :external,
      "app.bsky.embed.video"    => :video,
    }.freeze

    module_function

    def from_feed_view(post_hash)
      h = post_hash || {}
      author = h["author"] || {}
      record = h["record"] || {}
      reply  = record["reply"]

      {
        uri:          h["uri"],
        cid:          h["cid"],
        author: {
          did:          author["did"],
          handle:       author["handle"],
          display_name: author["displayName"],
        },
        text:         record["text"],
        created_at:   record["createdAt"],
        indexed_at:   h["indexedAt"],
        langs:        Array(record["langs"]),
        reply:        reply_view(reply),
        facets:       facets_view(record["facets"]),
        embed:        embed_view(h["embed"] || record["embed"]),
        like_count:   h["likeCount"]   || 0,
        repost_count: h["repostCount"] || 0,
        reply_count:  h["replyCount"]  || 0,
      }
    end

    def reply_view(reply)
      return nil unless reply.is_a?(Hash)
      parent = reply["parent"].is_a?(Hash) ? reply["parent"]["uri"] : nil
      root   = reply["root"].is_a?(Hash)   ? reply["root"]["uri"]   : nil
      { parent_uri: parent, root_uri: root }
    end

    def facets_view(facets)
      Array(facets).flat_map do |facet|
        idx = facet["index"] || {}
        Array(facet["features"]).filter_map do |feat|
          next unless feat["$type"] == "app.bsky.richtext.facet#link"
          {
            kind:       :link,
            uri:        feat["uri"],
            byte_start: idx["byteStart"],
            byte_end:   idx["byteEnd"],
          }
        end
      end
    end

    def embed_view(embed)
      return { kind: nil } unless embed.is_a?(Hash)
      type = embed["$type"].to_s.sub(/#view\z/, "")
      { kind: EMBED_KINDS[type] }
    end
  end
end
