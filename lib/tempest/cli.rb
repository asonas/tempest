require_relative "../tempest"
require_relative "config"
require_relative "session"
require_relative "session_store"
require_relative "cursor_store"
require_relative "timeline_store"
require_relative "xrpc_client"
require_relative "handle_resolver"
require_relative "follows"
require_relative "jetstream/client"
require_relative "jetstream/stream_manager"
require_relative "jetstream/subscription"
require_relative "repl/runner"
require_relative "repl/formatter"
require_relative "repl/async_output"
require_relative "repl/screen"

module Tempest
  module CLI
    module_function

    def run(argv: ARGV, env: ENV, stdout: $stdout, stderr: $stderr, stdin: $stdin,
            session_factory: Tempest::Session.method(:create),
            store: nil)
      if argv.include?("--version") || argv.include?("-v")
        stdout.puts "tempest #{Tempest::VERSION}"
        return 0
      end

      if argv.include?("--help") || argv.include?("-h")
        stdout.puts help_text
        return 0
      end

      Tempest::REPL::Formatter.color = stdout.respond_to?(:tty?) && stdout.tty? && env["NO_COLOR"].to_s.empty?

      store ||= Tempest::SessionStore.new(path: Tempest::SessionStore.default_path(env))
      session = sign_in(env, stdout, stdin, session_factory, store: store)
      client = Tempest::XRPCClient.new(session)
      input = RelineReader.new

      handle_resolver = Tempest::HandleResolver.new(client: client)
      handle_resolver.seed(session.did, session.handle)

      mode = feed_mode(argv: argv, env: env)
      plan = build_subscription(
        mode: mode, session: session, client: client,
        handle_resolver: handle_resolver, stdout: stdout,
      )

      jetstream_client = Tempest::Jetstream::Client.new(
        wanted_collections: ["app.bsky.feed.post"],
        wanted_dids: plan.wanted_dids,
      )
      stream_manager = Tempest::Jetstream::StreamManager.new(
        client: jetstream_client,
        cursor_store: cursor_store(env),
        filter: plan.filter,
      )

      stdout.puts "tempest #{Tempest::VERSION} — signed in as @#{session.handle}"
      stdout.puts "Type :help for commands, :quit to exit."

      screen = Tempest::REPL::Screen.new(io: stdout)
      screen.enable

      runner = Tempest::REPL::Runner.new(
        session: session,
        client: client,
        input: input,
        output: screen.enabled? ? screen : stdout,
        stream_output: screen.enabled? ? screen : Tempest::REPL::AsyncOutput.new(stdout),
        stream_manager: stream_manager,
        handle_resolver: handle_resolver,
        timeline_store: timeline_store(env),
      )

      begin
        runner.bootstrap_timeline

        if stream_default_on?(argv, env)
          runner.auto_start_stream
        end

        runner.run
        0
      ensure
        screen.disable
      end
    rescue Tempest::Config::MissingValue => e
      stderr.puts "configuration error: #{e.message}"
      stderr.puts "Set TEMPEST_IDENTIFIER and TEMPEST_APP_PASSWORD before launching."
      2
    rescue Tempest::AuthenticationError => e
      stderr.puts "authentication failed: #{e.message}"
      3
    rescue Tempest::Error => e
      stderr.puts "error: #{e.message}"
      1
    end

    def sign_in(env, stdout, stdin, session_factory, store:)
      identifier_hint = nil_if_empty(env["TEMPEST_IDENTIFIER"])
      pds_host_hint = nil_if_empty(env["TEMPEST_PDS_HOST"])

      if (existing = store.load(identifier: identifier_hint, pds_host: pds_host_hint))
        attach_store(existing, store, existing.identifier || identifier_hint)
        begin
          existing.refresh!
          return existing
        rescue Tempest::Error => e
          existing.on_change = nil
          stdout.puts "[tempest] cached session refresh failed: #{e.message}"
          stdout.puts "[tempest] cache kept at #{store.path}; falling back to TEMPEST_IDENTIFIER/TEMPEST_APP_PASSWORD"
        end
      end

      config = Tempest::Config.from_env(env)
      session = create_with_2fa(config, env, stdout, stdin, session_factory)
      attach_store(session, store, config.identifier)
      store.save(session, identifier: config.identifier)
      session
    end

    def nil_if_empty(value)
      value.nil? || value.empty? ? nil : value
    end

    def create_with_2fa(config, env, stdout, stdin, session_factory)
      token = env["TEMPEST_AUTH_FACTOR_TOKEN"]
      session_factory.call(config, auth_factor_token: token)
    rescue Tempest::AuthenticationError => e
      raise unless e.code == "AuthFactorTokenRequired" && token.nil?

      stdout.puts "Bluesky sent a sign-in code to your email. Enter it below."
      stdout.print "code: "
      stdout.flush
      code = stdin.gets&.strip
      raise Tempest::AuthenticationError.new("sign-in cancelled (no code entered)", code: e.code) if code.nil? || code.empty?

      session_factory.call(config, auth_factor_token: code)
    end

    def stream_default_on?(argv, env)
      return false if argv.include?("--no-stream")
      return false if env["TEMPEST_NO_STREAM"] == "1"
      true
    end

    def cursor_store(env)
      Tempest::CursorStore.new(path: Tempest::CursorStore.default_path(env))
    end

    def timeline_store(env)
      Tempest::TimelineStore.new(path: Tempest::TimelineStore.default_path(env))
    end

    VALID_FEED_MODES = %i[home self].freeze

    def feed_mode(argv:, env: {})
      flag = argv.find { |a| a.start_with?("--feed=") }&.split("=", 2)&.last
      raw = flag || env["TEMPEST_FEED"] || "home"

      mode = raw.to_sym
      raise ArgumentError, "invalid --feed value: #{raw.inspect} (must be home|self)" \
        unless VALID_FEED_MODES.include?(mode)
      mode
    end

    # Decides what the Jetstream subscription should look like for a freshly
    # signed-in session. In :self mode we only watch the user's own DID (the
    # historical earthquake-style "echo my posts" UX). In :home mode we fetch
    # the user's follows from AppView and let Subscription decide between
    # server-side wantedDids filtering and a firehose+client-filter fallback.
    # When a handle_resolver is provided, follow handles are seeded so the
    # live feed can render @handle without an extra getProfile roundtrip.
    def build_subscription(mode:, session:, client:, handle_resolver: nil, stdout: nil)
      case mode
      when :self
        Tempest::Jetstream::Plan.new(wanted_dids: [session.did], filter: nil)
      when :home
        stdout&.puts "[tempest] fetching follows..."
        follows = Tempest::Follows.fetch(client, actor: session.did)
        follows.each { |f| handle_resolver&.seed(f[:did], f[:handle]) }
        plan = Tempest::Jetstream::Subscription.build(self_did: session.did, follows: follows)
        if plan.filter
          stdout&.puts "[tempest] following #{follows.length} accounts (exceeds 10000 cap; using firehose+client-filter)"
        else
          stdout&.puts "[tempest] following #{follows.length} accounts"
        end
        plan
      else
        raise ArgumentError, "unknown feed mode: #{mode.inspect}"
      end
    end

    def attach_store(session, store, identifier)
      session.identifier ||= identifier
      session.on_change = ->(s) { store.save(s, identifier: s.identifier || identifier) }
    end

    def help_text
      <<~HELP
        Usage: tempest [options]

        Options:
          -h, --help       Show this help
          -v, --version    Show version
          --no-stream      Disable the auto-started Jetstream feed
          --feed=MODE      Choose what the live feed subscribes to:
                             home  (default) Your follows + your own posts
                             self  Only your own posts (legacy echo mode)

        Environment (required only when no cached session is available):
          TEMPEST_IDENTIFIER     Your handle (e.g. asonas.bsky.social)
          TEMPEST_APP_PASSWORD   An app password generated in Bluesky settings
          TEMPEST_PDS_HOST       Override PDS host (default: https://bsky.social)
          TEMPEST_AUTH_FACTOR_TOKEN
                                 Pre-supply an email sign-in code (rarely needed; the CLI will
                                 prompt interactively when Bluesky asks for one)
          TEMPEST_NO_STREAM      Set to 1 to disable the auto-started Jetstream feed
          TEMPEST_SESSION_PATH   Override the session cache path (default:
                                 $XDG_CONFIG_HOME/tempest/session.json or
                                 ~/.config/tempest/session.json). The cache holds refreshed
                                 tokens so the email sign-in code is only requested once.
          TEMPEST_CURSOR_PATH    Override the Jetstream cursor cache path (default:
                                 $XDG_CONFIG_HOME/tempest/cursor.json). Holds the last-seen
                                 time_us so a restart can replay missed events.
          TEMPEST_FEED           "home" (default) or "self"; equivalent to --feed.
      HELP
    end

    # Wraps Reline to fit the input interface expected by REPL::Runner.
    class RelineReader
      def initialize
        require "reline"
        @reline = Reline
      end

      def readline(prompt)
        @reline.readline(prompt, true)
      end
    end
  end
end
