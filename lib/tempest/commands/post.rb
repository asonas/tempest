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

        url = Tempest::Post.bsky_url(at_uri: response["uri"], handle: session.handle)

        if opts[:json]
          require "json"
          payload = { "uri" => response["uri"], "cid" => response["cid"] }
          payload["url"] = url if url
          stdout.puts JSON.generate(payload)
        else
          stdout.puts "posted: #{response["uri"]}"
          stdout.puts "url: #{url}" if url
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

      def build_reply(uri, client:)
        return nil if uri.nil? || uri.empty?
        Tempest::Post.fetch_reply_refs(client, uri)
      end
    end
  end
end
