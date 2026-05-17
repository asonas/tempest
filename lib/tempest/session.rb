require "base64"
require "json"

require_relative "../tempest"
require_relative "http"

module Tempest
  class Session
    EXPIRY_LEEWAY_SECONDS = 30

    attr_reader :access_jwt, :refresh_jwt, :did, :handle, :pds_host
    attr_accessor :on_change, :identifier

    def self.create(config, auth_factor_token: nil)
      url = "#{config.pds_host}/xrpc/com.atproto.server.createSession"
      body = { identifier: config.identifier, password: config.app_password }
      body[:authFactorToken] = auth_factor_token if auth_factor_token

      response = Tempest::HTTP.post_json(url, body: body)

      unless response.ok?
        details = response.body.is_a?(Hash) ? response.body : {}
        raise AuthenticationError.new(
          "createSession failed (#{response.status}): #{details["message"] || response.body.inspect}",
          code: details["error"],
        )
      end

      from_payload(response.body, pds_host: config.pds_host)
    end

    def self.from_payload(payload, pds_host:)
      new(
        access_jwt: payload.fetch("accessJwt"),
        refresh_jwt: payload.fetch("refreshJwt"),
        did: payload.fetch("did"),
        handle: payload.fetch("handle"),
        pds_host: pds_host,
      )
    end

    def initialize(access_jwt:, refresh_jwt:, did:, handle:, pds_host:, identifier: nil)
      @access_jwt = access_jwt
      @refresh_jwt = refresh_jwt
      @did = did
      @handle = handle
      @pds_host = pds_host
      @identifier = identifier
      @refresh_mutex = Mutex.new
    end

    def access_expired?
      exp = jwt_exp(@access_jwt)
      return true if exp.nil?
      Time.now.to_i + EXPIRY_LEEWAY_SECONDS >= exp
    end

    # Refreshes the session using the current refresh_jwt.
    #
    # When `if_unchanged_from:` is supplied, the refresh is skipped if the
    # session's access_jwt has already moved past that value. Combined with the
    # internal mutex, this lets concurrent callers coalesce a single
    # refreshSession round-trip: the first caller refreshes while the rest wait
    # for the lock and then observe the new token, no-op'ing instead of issuing
    # duplicate refresh requests.
    def refresh!(if_unchanged_from: nil)
      @refresh_mutex.synchronize do
        return self if if_unchanged_from && @access_jwt != if_unchanged_from

        perform_refresh
      end
    end

    private

    def perform_refresh
      url = "#{@pds_host}/xrpc/com.atproto.server.refreshSession"
      response = Tempest::HTTP.post_json(
        url,
        headers: { "Authorization" => "Bearer #{@refresh_jwt}" },
      )

      unless response.ok?
        details = response.body.is_a?(Hash) ? response.body : {}
        raise AuthenticationError.new(
          "refreshSession failed (#{response.status}): #{details["message"] || response.body.inspect}",
          code: details["error"],
        )
      end

      @access_jwt = response.body.fetch("accessJwt")
      @refresh_jwt = response.body.fetch("refreshJwt")
      @did = response.body.fetch("did")
      @handle = response.body.fetch("handle")
      @on_change&.call(self)
      self
    end

    def jwt_exp(token)
      _, payload, _ = token.split(".")
      return nil if payload.nil?
      decoded = Base64.urlsafe_decode64(payload + "=" * ((4 - payload.size % 4) % 4))
      JSON.parse(decoded)["exp"]
    rescue ArgumentError, JSON::ParserError
      nil
    end
  end
end
