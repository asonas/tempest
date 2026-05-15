require "set"

require_relative "../../tempest"

module Tempest
  module Jetstream
    # Decides whether the Jetstream subscription can use server-side wantedDids
    # filtering or has to fall back to a firehose-plus-client-side-filter
    # arrangement. Jetstream caps wantedDids at 10000 DIDs per subscription, so
    # anyone following more than that has to receive the full stream and drop
    # uninteresting events locally.
    Plan = Data.define(:wanted_dids, :filter)

    module Subscription
      module_function

      def build(self_did:, follows:, cap: 10_000)
        ordered = [self_did]
        follows.each do |row|
          did = row[:did] || row["did"]
          next if did.nil? || did == self_did
          ordered << did
        end

        if ordered.length <= cap
          Plan.new(wanted_dids: ordered, filter: nil)
        else
          allowed = ordered.to_set
          Plan.new(wanted_dids: [], filter: ->(event) { allowed.include?(event.did) })
        end
      end
    end
  end
end
