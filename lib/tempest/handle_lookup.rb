require_relative "../tempest"

module Tempest
  module HandleLookup
    module_function

    def resolve(actor, client:)
      input = actor.to_s.sub(/\A@/, "")
      return input if input.start_with?("did:")
      response = client.get("app.bsky.actor.getProfile", query: { "actor" => input })
      response.fetch("did")
    end
  end
end
