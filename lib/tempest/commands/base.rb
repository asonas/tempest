require_relative "../commands"
require_relative "../session_store"
require_relative "../accounts_store"
require_relative "../accounts_migration"
require_relative "../config"
require_relative "../repl/formatter"

module Tempest
  module Commands
    module Base
      module_function

      VALID_FORMATS = %i[line json raw].freeze

      # Loads the per-account cached session and refreshes it. Returns the
      # session on success. On failure writes a human-readable line to stderr
      # and returns nil; callers translate the nil into the appropriate exit
      # code via `exit_code_for` (or `authenticate_with_code` for a more
      # specific exit code).
      #
      # `user:` is the value of the global `--user <handle|did>` flag, or nil
      # for the default account.
      def authenticate(env:, stderr:, user: nil, logger: nil)
        session, _code = authenticate_with_code(env: env, stderr: stderr, user: user, logger: logger)
        session
      end

      # Like `authenticate` but additionally returns the exit code that the CLI
      # should use when session is nil. Exit codes follow the spec:
      # 2 for "unknown user" / "no accounts configured", 3 for session missing
      # or refresh failure.
      def authenticate_with_code(env:, stderr:, user: nil, logger: nil)
        Tempest::AccountsMigration.run(env: env, stderr: stderr, logger: logger)
        accounts = Tempest::AccountsStore.new(env: env, logger: logger)

        target = resolve_target(accounts, user, stderr)
        return [nil, 2] if target.nil?

        session_store = Tempest::SessionStore.for(env, did: target.did)
        session = session_store.load(identifier: nil, pds_host: nil)
        if session.nil?
          stderr.puts "error: session for @#{target.handle} missing — run `tempest login` to re-authenticate"
          return [nil, 3]
        end

        session.identifier ||= target.identifier
        session.on_change = ->(s) {
          session_store.save(s, identifier: s.identifier || target.identifier)
          accounts.update_handle(did: s.did, handle: s.handle) if s.did && s.handle
        }

        begin
          session.refresh!
        rescue Tempest::Error => e
          stderr.puts "error: session for @#{target.handle} expired — run `tempest login` to re-authenticate (#{e.message})"
          return [nil, 3]
        end
        [session, 0]
      end

      def resolve_target(accounts, user, stderr)
        if user
          target = accounts.resolve(user)
          if target.nil?
            stderr.puts "error: unknown user: #{user} (run `tempest accounts list` to see known accounts)"
            return nil
          end
          return target
        end

        if accounts.default
          return accounts.resolve(accounts.default)
        end

        if accounts.accounts.empty?
          stderr.puts "error: no accounts configured — run `tempest login` to add one"
          return nil
        end

        stderr.puts "error: no default account set — run `tempest accounts set-default <handle>`"
        nil
      end

      # Returns one of :line, :json, :raw. Callers may override with --format.
      def default_format(stdout:, env:)
        stdout.respond_to?(:tty?) && stdout.tty? ? :line : :json
      end

      # Parses --format=NAME from argv (destructive: returns [format, argv_without_flag]).
      # Raises ArgumentError on unknown format names.
      def take_format(argv, default:)
        out = []
        chosen = default
        argv.each do |arg|
          if (m = arg.match(/\A--format=(\S+)\z/))
            sym = m[1].to_sym
            raise ArgumentError, "invalid --format: #{m[1].inspect}" unless VALID_FORMATS.include?(sym)
            chosen = sym
          elsif arg == "--no-color"
            Tempest::REPL::Formatter.color = false if defined?(Tempest::REPL::Formatter)
          else
            out << arg
          end
        end
        [chosen, out]
      end

      def exit_code_for(error)
        case error
        when Tempest::Config::MissingValue then 2
        when Tempest::AuthenticationError  then 3
        when Tempest::APIError             then 4
        when ArgumentError                 then 64
        else                                    1
        end
      end
    end
  end
end
