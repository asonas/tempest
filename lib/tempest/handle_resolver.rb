require_relative "../tempest"

module Tempest
  # Resolves AT Protocol DIDs to Bluesky handles via app.bsky.actor.getProfile.
  # Caches both positive and negative lookups in-process so a busy Jetstream
  # feed doesn't hammer the PDS on every event.
  class HandleResolver
    NOT_FOUND = Object.new.freeze

    def initialize(client:)
      @client = client
      @cache = {}
      @mutex = Mutex.new
    end

    def resolve(did)
      cached = @mutex.synchronize { @cache[did] }
      return cached_value(cached) unless cached.nil?

      handle = lookup(did)
      @mutex.synchronize { @cache[did] = handle.nil? ? NOT_FOUND : handle }
      handle
    end

    def seed(did, handle)
      @mutex.synchronize { @cache[did] = handle }
    end

    private

    def cached_value(value)
      value.equal?(NOT_FOUND) ? nil : value
    end

    def lookup(did)
      response = @client.get("app.bsky.actor.getProfile", query: { "actor" => did })
      response.is_a?(Hash) ? response["handle"] : nil
    rescue Tempest::APIError
      nil
    end
  end
end
