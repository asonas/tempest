require "fileutils"
require "json"

require_relative "../tempest"
require_relative "account_paths"
require_relative "session"

module Tempest
  class SessionStore
    def self.default_path(env = ENV)
      Tempest::AccountPaths.legacy_session_path(env)
    end

    def self.for(env = ENV, did:)
      new(path: Tempest::AccountPaths.session_path(env, did: did))
    end

    def initialize(path:)
      @path = path
    end

    attr_reader :path

    def save(session, identifier:)
      payload = {
        "identifier" => identifier,
        "pds_host" => session.pds_host,
        "did" => session.did,
        "handle" => session.handle,
        "access_jwt" => session.access_jwt,
        "refresh_jwt" => session.refresh_jwt,
      }

      FileUtils.mkdir_p(File.dirname(@path), mode: 0o700)
      File.open(@path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |io|
        io.write(JSON.generate(payload))
      end
      File.chmod(0o600, @path)
    end

    def load(identifier: nil, pds_host: nil)
      return nil unless File.exist?(@path)

      raw = File.read(@path)
      data = JSON.parse(raw)
      return nil unless data.is_a?(Hash)
      return nil if identifier && data["identifier"] != identifier
      return nil if pds_host && data["pds_host"] != pds_host

      Tempest::Session.new(
        access_jwt: data.fetch("access_jwt"),
        refresh_jwt: data.fetch("refresh_jwt"),
        did: data.fetch("did"),
        handle: data.fetch("handle"),
        pds_host: data.fetch("pds_host"),
        identifier: data["identifier"],
      )
    rescue JSON::ParserError, KeyError
      nil
    end

    def clear
      File.delete(@path) if File.exist?(@path)
    end
  end
end
