require_relative "../commands"
require_relative "../commands/base"
require_relative "../handle_lookup"

module Tempest
  module Commands
    module Follow
      module_function

      def call(argv:, session:, client:, stdout:, stderr:)
        handle = argv.first
        if handle.nil? || handle.empty?
          stderr.puts "usage: tempest follow <handle>"
          return 64
        end

        did = Tempest::HandleLookup.resolve(handle, client: client)
        client.post(
          "com.atproto.repo.createRecord",
          body: {
            "repo"       => session.did,
            "collection" => "app.bsky.graph.follow",
            "record"     => {
              "$type"     => "app.bsky.graph.follow",
              "subject"   => did,
              "createdAt" => Time.now.utc.iso8601,
            },
          },
        )
        stdout.puts "Followed @#{handle}"
        0
      end
    end
  end
end
