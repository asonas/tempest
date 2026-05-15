require_relative "../tempest"
require_relative "post"

module Tempest
  module Timeline
    DEFAULT_LIMIT = 50

    module_function

    def fetch(client, limit: DEFAULT_LIMIT)
      response = client.get("app.bsky.feed.getTimeline", query: { "limit" => limit })
      Array(response["feed"]).map { |entry| Post.from_feed_view(entry["post"]) }
    end
  end
end
