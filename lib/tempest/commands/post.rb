require_relative "../commands"
require_relative "../post"

module Tempest
  module Commands
    module Post
      MAX_GRAPHEMES = 300

      module_function

      def call(argv:, session:, client:, stdout:, stderr:, stdin:)
        opts, positional = parse(argv)
        return 64 if opts[:invalid]

        text = read_text(positional, stdin: stdin)
        if text.nil? || text.strip.empty?
          stderr.puts "error: empty post text"
          return 64
        end
        if text.grapheme_clusters.length > MAX_GRAPHEMES
          stderr.puts "error: post exceeds #{MAX_GRAPHEMES} graphemes"
          return 64
        end

        reply = build_reply(opts[:reply_to], client: client)

        response = Tempest::Post.create(
          client, did: session.did, text: text, reply: reply,
          langs: opts[:langs],
        )

        if opts[:json]
          require "json"
          stdout.puts JSON.generate(
            "uri" => response["uri"], "cid" => response["cid"],
          )
        else
          stdout.puts "posted: #{response["uri"]}"
        end
        0
      end

      def parse(argv)
        opts = { langs: ["ja"], json: false, reply_to: nil, invalid: false }
        positional = []
        i = 0
        while i < argv.length
          a = argv[i]
          case a
          when "--lang"
            opts[:langs] = argv[i + 1].to_s.split(",")
            i += 2
          when /\A--lang=(.+)\z/
            opts[:langs] = $1.split(",")
            i += 1
          when "--reply-to"
            opts[:reply_to] = argv[i + 1]
            i += 2
          when /\A--reply-to=(.+)\z/
            opts[:reply_to] = $1
            i += 1
          when "--json"
            opts[:json] = true
            i += 1
          else
            positional << a
            i += 1
          end
        end
        [opts, positional]
      end

      def read_text(positional, stdin:)
        if positional == ["-"]
          stdin.read.to_s.chomp
        else
          positional.join(" ")
        end
      end

      # Look up the parent's cid via com.atproto.repo.getRecord. AT Proto
      # requires both uri and cid on a reply ref; we only have the URI from
      # the CLI flag, so the lookup is necessary.
      def build_reply(uri, client:)
        return nil if uri.nil? || uri.empty?
        repo, collection, rkey = parse_at_uri(uri)
        record = client.get(
          "com.atproto.repo.getRecord",
          query: { "repo" => repo, "collection" => collection, "rkey" => rkey },
        )
        { uri: record.fetch("uri"), cid: record.fetch("cid") }
      end

      def parse_at_uri(uri)
        match = uri.match(%r{\Aat://([^/]+)/([^/]+)/(.+)\z})
        raise ArgumentError, "invalid at:// URI: #{uri.inspect}" unless match
        [match[1], match[2], match[3]]
      end
    end
  end
end
