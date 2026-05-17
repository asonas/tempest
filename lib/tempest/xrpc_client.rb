require_relative "../tempest"
require_relative "http"

module Tempest
  class XRPCClient
    def initialize(session)
      @session = session
    end

    def get(nsid, query: nil)
      perform { |access_jwt|
        Tempest::HTTP.get_json(
          endpoint(nsid),
          headers: auth_headers(access_jwt),
          query: query,
        )
      }
    end

    def post(nsid, body:)
      perform { |access_jwt|
        Tempest::HTTP.post_json(
          endpoint(nsid),
          headers: auth_headers(access_jwt),
          body: body,
        )
      }
    end

    private

    def endpoint(nsid)
      "#{@session.pds_host}/xrpc/#{nsid}"
    end

    def auth_headers(access_jwt)
      { "Authorization" => "Bearer #{access_jwt}" }
    end

    def perform
      response = yield(@session.access_jwt)

      if auth_expired_response?(response)
        @session.refresh!
        response = yield(@session.access_jwt)
      end

      raise Tempest::APIError.new(response.status, response.body) unless response.ok?

      response.body
    end

    def auth_expired_response?(response)
      return true if response.unauthorized?
      return false unless response.status == 400
      return false unless response.body.is_a?(Hash)

      response.body["error"] == "ExpiredToken"
    end
  end
end
