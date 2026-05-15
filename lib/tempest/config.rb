require_relative "../tempest"

module Tempest
  class Config
    class MissingValue < Tempest::Error; end

    DEFAULT_PDS_HOST = "https://bsky.social".freeze

    attr_reader :identifier, :app_password, :pds_host

    def self.from_env(env = ENV)
      identifier = env["TEMPEST_IDENTIFIER"]
      raise MissingValue, "TEMPEST_IDENTIFIER is not set" if identifier.nil? || identifier.empty?

      app_password = env["TEMPEST_APP_PASSWORD"]
      raise MissingValue, "TEMPEST_APP_PASSWORD is not set" if app_password.nil? || app_password.empty?

      pds_host = env["TEMPEST_PDS_HOST"]
      pds_host = DEFAULT_PDS_HOST if pds_host.nil? || pds_host.empty?

      new(identifier: identifier, app_password: app_password, pds_host: pds_host)
    end

    def initialize(identifier:, app_password:, pds_host: DEFAULT_PDS_HOST)
      @identifier = identifier
      @app_password = app_password
      @pds_host = pds_host
    end
  end
end
