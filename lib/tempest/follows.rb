require_relative "../tempest"

module Tempest
  # Fetches the authenticated user's follow list via app.bsky.graph.getFollows.
  # Returns a flat array of `{did:, handle:}` so callers can both warm the
  # HandleResolver and build a Jetstream `wantedDids` filter from a single
  # pass.
  module Follows
    PAGE_LIMIT = 100

    module_function

    def fetch(client, actor:)
      results = []
      cursor = nil

      loop do
        response = client.get(
          "app.bsky.graph.getFollows",
          query: { actor: actor, limit: PAGE_LIMIT, cursor: cursor },
        )

        Array(response["follows"]).each do |row|
          did = row["did"]
          handle = row["handle"]
          results << { did: did, handle: handle } if did
        end

        cursor = response["cursor"]
        break if cursor.nil? || cursor.empty?
      end

      results
    end
  end
end
