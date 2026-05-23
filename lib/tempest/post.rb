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
    # `reply` is `{ root: {uri:, cid:}, parent: {uri:, cid:} }` so callers can
    # preserve the original conversation root when replying deep in a thread.
    # Use `fetch_reply_refs` to build this from a parent URI.
    def self.create(client, did:, text:, reply: nil, langs: nil,
                    created_at: Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ"))
      record = {
        "$type" => "app.bsky.feed.post",
        "text" => text,
        "createdAt" => created_at,
      }
      if reply
        record["reply"] = {
          "root"   => { "uri" => reply[:root][:uri],   "cid" => reply[:root][:cid] },
          "parent" => { "uri" => reply[:parent][:uri], "cid" => reply[:parent][:cid] },
        }
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

    # Looks up `parent_uri` via com.atproto.repo.getRecord and returns reply
    # refs that preserve the conversation root. If the parent is itself a
    # reply, the parent's `reply.root` is reused so the new reply joins the
    # original thread. If the parent is a top-level post, the parent stands
    # in as the root (root and parent point at the same record).
    def self.fetch_reply_refs(client, parent_uri)
      match = parent_uri.to_s.match(%r{\Aat://([^/]+)/([^/]+)/(.+)\z})
      raise ArgumentError, "invalid at:// URI: #{parent_uri.inspect}" unless match

      record = client.get(
        "com.atproto.repo.getRecord",
        query: { "repo" => match[1], "collection" => match[2], "rkey" => match[3] },
      )
      parent_ref = { uri: record.fetch("uri"), cid: record.fetch("cid") }
      parent_root = record.dig("value", "reply", "root")
      root_ref =
        if parent_root.is_a?(Hash) && parent_root["uri"] && parent_root["cid"]
          { uri: parent_root["uri"], cid: parent_root["cid"] }
        else
          parent_ref
        end
      { root: root_ref, parent: parent_ref }
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
