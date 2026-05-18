require_relative "../tempest"

module Tempest
  # Centralizes filesystem layout for tempest's per-account storage.
  #
  # Legacy paths (`legacy_*`) honor `TEMPEST_SESSION_PATH` /
  # `TEMPEST_CURSOR_PATH` / `TEMPEST_TIMELINE_PATH` for migration purposes only;
  # the new per-DID paths cannot be overridden via env.
  module AccountPaths
    module_function

    def config_base(env = ENV)
      base = env["XDG_CONFIG_HOME"]
      base = File.join(env["HOME"].to_s, ".config") if base.nil? || base.empty?
      File.join(base, "tempest")
    end

    def legacy_session_path(env = ENV)
      explicit = env["TEMPEST_SESSION_PATH"]
      return explicit if explicit && !explicit.empty?
      File.join(config_base(env), "session.json")
    end

    def legacy_cursor_path(env = ENV)
      explicit = env["TEMPEST_CURSOR_PATH"]
      return explicit if explicit && !explicit.empty?
      File.join(config_base(env), "cursor.json")
    end

    def legacy_timeline_path(env = ENV)
      explicit = env["TEMPEST_TIMELINE_PATH"]
      return explicit if explicit && !explicit.empty?
      File.join(config_base(env), "timeline.json")
    end

    def accounts_dir(env = ENV)
      File.join(config_base(env), "accounts")
    end

    def account_dir(env = ENV, did:)
      File.join(accounts_dir(env), did)
    end

    def session_path(env = ENV, did:)
      File.join(account_dir(env, did: did), "session.json")
    end

    def cursor_path(env = ENV, did:)
      File.join(account_dir(env, did: did), "cursor.json")
    end

    def timeline_path(env = ENV, did:)
      File.join(account_dir(env, did: did), "timeline.json")
    end

    def accounts_json_path(env = ENV)
      File.join(config_base(env), "accounts.json")
    end
  end
end
