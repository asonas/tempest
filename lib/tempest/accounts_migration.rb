require "fileutils"
require "json"
require "time"

require_relative "../tempest"
require_relative "account_paths"
require_relative "accounts_store"

module Tempest
  # One-shot, idempotent migration that converts the legacy single-account
  # layout (<base>/session.json etc.) into the per-DID layout introduced in
  # 0.3.0 (<base>/accounts/<did>/session.json + <base>/accounts.json).
  #
  # Runs at the top of every command entry point. The presence of accounts.json
  # is the completion marker; partial failures recover automatically thanks to
  # `File.rename`'s atomicity and AccountsStore's orphan self-heal.
  module AccountsMigration
    module_function

    # Returns one of :migrated, :skipped, :noop. :migrated is the only state
    # that produces stderr output.
    def run(env: ENV, stderr: $stderr, logger: nil)
      accounts_json = Tempest::AccountPaths.accounts_json_path(env)
      return :skipped if File.exist?(accounts_json)

      legacy_session = Tempest::AccountPaths.legacy_session_path(env)
      return :noop unless File.exist?(legacy_session)

      data = JSON.parse(File.read(legacy_session))
      did = data.fetch("did")
      handle = data.fetch("handle")
      identifier = data["identifier"] || handle
      pds_host = data["pds_host"] || Tempest::Config::DEFAULT_PDS_HOST

      account_dir = Tempest::AccountPaths.account_dir(env, did: did)
      FileUtils.mkdir_p(Tempest::AccountPaths.accounts_dir(env), mode: 0o700)
      FileUtils.mkdir_p(account_dir, mode: 0o700)

      File.rename(legacy_session, Tempest::AccountPaths.session_path(env, did: did))

      legacy_cursor = Tempest::AccountPaths.legacy_cursor_path(env)
      if File.exist?(legacy_cursor)
        File.rename(legacy_cursor, Tempest::AccountPaths.cursor_path(env, did: did))
      end

      legacy_timeline = Tempest::AccountPaths.legacy_timeline_path(env)
      if File.exist?(legacy_timeline)
        File.rename(legacy_timeline, Tempest::AccountPaths.timeline_path(env, did: did))
      end

      store = Tempest::AccountsStore.new(env: env, logger: logger)
      store.add_account(
        did: did,
        handle: handle,
        identifier: identifier,
        pds_host: pds_host,
        added_at: Time.now.utc,
      )

      logger&.info("accounts", event: "migrated", did: did, account_dir: account_dir)
      stderr.puts "[tempest] migrated session to #{account_dir}/"
      :migrated
    end
  end
end
