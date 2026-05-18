require "io/console"
require "time"

require_relative "../commands"
require_relative "../accounts_store"
require_relative "../accounts_migration"
require_relative "../config"
require_relative "../session"
require_relative "../session_store"

module Tempest
  module Commands
    # `tempest login` — adds a Bluesky account to tempest.
    #
    # Always reads identifier and app password interactively from stdin (env
    # vars are intentionally not honored — see plan §F2). Optional
    # `--pds-host=<url>` selects a non-bsky.social PDS. On success, persists
    # the per-DID session.json and registers the account in accounts.json
    # (becoming default if it is the first account).
    module Login
      module_function

      DEFAULT_PDS_HOST = Tempest::Config::DEFAULT_PDS_HOST

      def call(argv:, env:, stdout:, stderr:, stdin:, session_factory: nil)
        Tempest::AccountsMigration.run(env: env, stderr: stderr)
        session_factory ||= Tempest::Session.method(:create)

        pds_host, _rest = parse(argv, stderr: stderr)
        return 64 if pds_host == :error

        stdout.print "identifier: "
        stdout.flush
        identifier = stdin.gets&.strip
        if identifier.nil? || identifier.empty?
          stderr.puts "error: identifier required"
          return 64
        end

        password = read_password(stdout, stdin)
        if password.nil? || password.empty?
          stderr.puts "error: app password required"
          return 64
        end

        stdout.puts "signing in..."
        stdout.flush

        config = Tempest::Config.new(
          identifier: identifier,
          app_password: password,
          pds_host: pds_host,
        )

        session = create_with_2fa(config, stdout, stdin, session_factory)

        session_store = Tempest::SessionStore.for(env, did: session.did)
        session.identifier ||= identifier
        session_store.save(session, identifier: identifier)

        accounts = Tempest::AccountsStore.new(env: env)
        accounts.add_account(
          did: session.did,
          handle: session.handle,
          identifier: identifier,
          pds_host: pds_host,
          added_at: Time.now.utc,
        )

        stdout.puts "logged in as @#{session.handle} (#{session.did})"
        0
      rescue Tempest::AuthenticationError => e
        stderr.puts "error: login failed: #{e.message}"
        3
      end

      def parse(argv, stderr:)
        pds_host = DEFAULT_PDS_HOST
        rest = []
        argv.each do |arg|
          if (m = arg.match(/\A--pds-host=(.+)\z/))
            pds_host = m[1]
          else
            rest << arg
          end
        end
        [pds_host, rest]
      end

      def read_password(stdout, stdin)
        stdout.print "app password: "
        stdout.flush
        if stdin.respond_to?(:noecho)
          password = stdin.noecho(&:gets)
          stdout.puts ""
          password&.strip
        else
          stdin.gets&.strip
        end
      end

      def create_with_2fa(config, stdout, stdin, session_factory)
        session_factory.call(config, auth_factor_token: nil)
      rescue Tempest::AuthenticationError => e
        raise unless e.code == "AuthFactorTokenRequired"

        stdout.puts "Bluesky sent a sign-in code to your email. Enter it below."
        stdout.print "code: "
        stdout.flush
        code = stdin.gets&.strip
        raise Tempest::AuthenticationError.new("sign-in cancelled (no code entered)", code: e.code) if code.nil? || code.empty?

        session_factory.call(config, auth_factor_token: code)
      end
    end
  end
end
