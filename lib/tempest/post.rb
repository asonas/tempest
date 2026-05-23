require_relative "../tempest"
require_relative "facet"

module Tempest
  Post = Data.define(:uri, :cid, :handle, :display_name, :text, :created_at, :facets, :reply_parent_uri, :embed_kind) do
    # AT Protocol embed `$type` values mapped to short symbols used by the
    # REPL. `record` (quote) and `external` (link card) are intentionally
    # absent: they're surfaced through other UI (URL annotation), so they
    # don't get a media-marker emoji.
    EMBED_KINDS = {
      "app.bsky.embed.images" => :images,
      "app.bsky.embed.video"  => :video,
    }.freeze

    def initialize(uri:, cid:, handle:, display_name:, text:, created_at:,
                   facets: [], reply_parent_uri: nil, embed_kind: nil)
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
        embed_kind: embed_kind_from(post["embed"] || record["embed"]),
      )
    end

    # The view-side `$type` carries a `#view` suffix (e.g.
    # `app.bsky.embed.images#view`); the raw record uses the bare form.
    # Strip the suffix before looking up so both feed and Jetstream payloads
    # classify identically.
    def self.embed_kind_from(embed)
      return nil unless embed.is_a?(Hash)
      type = embed["$type"].to_s.sub(/#view\z/, "")
      EMBED_KINDS[type]
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

    # Compose an app.bsky.feed.like record referencing the subject post and
    # send it via com.atproto.repo.createRecord. The AppView surfaces this in
    # like counts and notifications for the target post.
    def self.like(client, did:, subject_uri:, subject_cid:,
                  created_at: Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ"))
      record = {
        "$type" => "app.bsky.feed.like",
        "subject" => { "uri" => subject_uri, "cid" => subject_cid },
        "createdAt" => created_at,
      }
      client.post(
        "com.atproto.repo.createRecord",
        body: {
          repo: did,
          collection: "app.bsky.feed.like",
          record: record,
        },
      )
    end

    # Builds a bsky.app web URL from an at:// post URI. `handle` is preferred
    # because human-readable URLs are nicer for sharing; when missing or empty
    # the DID is used (bsky.app accepts both forms in the profile path).
    # Returns nil when the URI is not an `app.bsky.feed.post` record.
    def self.bsky_url(at_uri:, handle: nil)
      match = at_uri.to_s.match(%r{\Aat://([^/]+)/app\.bsky\.feed\.post/(.+)\z})
      return nil unless match

      did = match[1]
      rkey = match[2]
      profile = handle && !handle.empty? ? handle : did
      "https://bsky.app/profile/#{profile}/post/#{rkey}"
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
