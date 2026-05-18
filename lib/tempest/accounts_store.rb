require "fileutils"
require "json"
require "set"
require "time"

require_relative "../tempest"
require_relative "account_paths"
require_relative "config"
require_relative "session_store"

module Tempest
  # Tracks which Bluesky accounts tempest knows about and which one is currently
  # the default. The on-disk representation is `<config_base>/accounts.json`,
  # always rewritten via tmp + rename for atomicity (see `write_atomic`).
  #
  # On construction, also performs an orphan-recovery sweep so that any
  # `accounts/<did>/session.json` left behind by a partial login or migration
  # appears in accounts.json the next time tempest starts.
  class AccountsStore
    SCHEMA_VERSION = 1

    Account = Data.define(:did, :handle, :identifier, :pds_host, :added_at)

    def initialize(env: ENV, path: nil, logger: nil)
      @env = env
      @path = path || Tempest::AccountPaths.accounts_json_path(env)
      @logger = logger
      @default = nil
      @accounts = []
      load
      self_heal
    end

    attr_reader :default, :accounts

    def resolve(value)
      return nil if value.nil? || value.empty?
      by_did = @accounts.find { |a| a.did == value }
      return by_did if by_did
      @accounts.find { |a| a.handle == value }
    end

    def set_default(value)
      account = resolve(value)
      raise ArgumentError, "unknown user: #{value}" if account.nil?
      return account.did if @default == account.did
      @default = account.did
      persist
      @logger&.info("accounts", event: "set_default", handle: account.handle, did: account.did)
      account.did
    end

    def add_account(did:, handle:, identifier:, pds_host:, added_at: Time.now.utc)
      existing = @accounts.find { |a| a.did == did }
      effective_added_at = existing ? existing.added_at : added_at
      replacement = Account.new(
        did: did,
        handle: handle,
        identifier: identifier,
        pds_host: pds_host,
        added_at: effective_added_at,
      )

      list = @accounts.reject { |a| a.did == did } + [replacement]
      @accounts = list.sort_by(&:added_at).freeze
      @default ||= did
      persist
      replacement
    end

    def update_handle(did:, handle:)
      target = @accounts.find { |a| a.did == did }
      return if target.nil?
      return if target.handle == handle

      old_handle = target.handle
      replacement = Account.new(
        did: target.did,
        handle: handle,
        identifier: target.identifier,
        pds_host: target.pds_host,
        added_at: target.added_at,
      )
      list = @accounts.reject { |a| a.did == did } + [replacement]
      @accounts = list.sort_by(&:added_at).freeze
      persist
      @logger&.info("accounts", event: "handle_changed", did: did, old_handle: old_handle, new_handle: handle)
    end

    private

    def load
      return unless File.exist?(@path)

      raw = File.read(@path)
      data = JSON.parse(raw)
      unless data.is_a?(Hash) && data["version"] == SCHEMA_VERSION
        @default = nil
        @accounts = []
        return
      end

      @default = data["default"]
      @accounts = Array(data["accounts"]).filter_map { |hash| build_account(hash) }
                                         .sort_by { |a| a.added_at }
      @accounts.freeze
    rescue JSON::ParserError
      @default = nil
      @accounts = []
    end

    def build_account(hash)
      return nil unless hash.is_a?(Hash)
      did = hash["did"]
      handle = hash["handle"]
      return nil if did.nil? || handle.nil?

      Account.new(
        did: did,
        handle: handle,
        identifier: hash["identifier"] || handle,
        pds_host: hash["pds_host"] || Tempest::Config::DEFAULT_PDS_HOST,
        added_at: parse_time(hash["added_at"]),
      )
    end

    def parse_time(value)
      return Time.now.utc if value.nil? || value.to_s.empty?
      Time.iso8601(value)
    rescue ArgumentError
      Time.now.utc
    end

    def self_heal
      dir = Tempest::AccountPaths.accounts_dir(@env)
      return unless File.directory?(dir)

      known = @accounts.map(&:did).to_set
      changed = false
      Dir.children(dir).each do |entry|
        did = entry
        next if known.include?(did)
        session_path = Tempest::AccountPaths.session_path(@env, did: did)
        next unless File.exist?(session_path)

        adopted = adopt_orphan_session(did, session_path)
        if adopted
          @accounts = (@accounts.reject { |a| a.did == did } + [adopted]).sort_by(&:added_at).freeze
          @default ||= did
          changed = true
          @logger&.info("accounts", event: "orphan_recovered", did: did, handle: adopted.handle)
        end
      end
      persist if changed
    end

    def adopt_orphan_session(did, session_path)
      raw = File.read(session_path)
      data = JSON.parse(raw)
      return nil unless data.is_a?(Hash)
      handle = data["handle"] || data["identifier"]
      return nil if handle.nil?

      Account.new(
        did: did,
        handle: handle,
        identifier: data["identifier"] || handle,
        pds_host: data["pds_host"] || Tempest::Config::DEFAULT_PDS_HOST,
        added_at: File.mtime(session_path).utc,
      )
    rescue JSON::ParserError
      @logger&.warn("accounts", event: "orphan_malformed", did: did)
      nil
    end

    def persist
      payload = {
        "version" => SCHEMA_VERSION,
        "default" => @default,
        "accounts" => @accounts.map { |a|
          {
            "did" => a.did,
            "handle" => a.handle,
            "identifier" => a.identifier,
            "pds_host" => a.pds_host,
            "added_at" => a.added_at.utc.iso8601(6),
          }
        },
      }
      write_atomic(JSON.generate(payload))
    end

    def write_atomic(content)
      FileUtils.mkdir_p(File.dirname(@path), mode: 0o700)
      tmp = "#{@path}.tmp.#{Process.pid}"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |io|
        io.write(content)
      end
      File.chmod(0o600, tmp)
      File.rename(tmp, @path)
    ensure
      File.delete(tmp) if tmp && File.exist?(tmp)
    end
  end
end
