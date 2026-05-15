require "base64"
require "json"

require_relative "../tempest"
require_relative "http"

module Tempest
  class Session
    EXPIRY_LEEWAY_SECONDS = 30

    attr_reader :access_jwt, :refresh_jwt, :did, :handle, :pds_host

    def self.create(config)
      url = "#{config.pds_host}/xrpc/com.atproto.server.createSession"
      response = Tempest::HTTP.post_json(
        url,
        body: { identifier: config.identifier, password: config.app_password },
      )

      unless response.ok?
        message = response.body.is_a?(Hash) ? response.body["message"] : response.body.to_s
        raise AuthenticationError, "createSession failed (#{response.status}): #{message}"
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

    def initialize(access_jwt:, refresh_jwt:, did:, handle:, pds_host:)
      @access_jwt = access_jwt
      @refresh_jwt = refresh_jwt
      @did = did
      @handle = handle
      @pds_host = pds_host
    end

    def access_expired?
      exp = jwt_exp(@access_jwt)
      return true if exp.nil?
      Time.now.to_i + EXPIRY_LEEWAY_SECONDS >= exp
    end

    def refresh!
      url = "#{@pds_host}/xrpc/com.atproto.server.refreshSession"
      response = Tempest::HTTP.post_json(
        url,
        headers: { "Authorization" => "Bearer #{@refresh_jwt}" },
        body: {},
      )

      raise AuthenticationError, "refreshSession failed (#{response.status})" unless response.ok?

      @access_jwt = response.body.fetch("accessJwt")
      @refresh_jwt = response.body.fetch("refreshJwt")
      @did = response.body.fetch("did")
      @handle = response.body.fetch("handle")
      self
    end

    private

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
