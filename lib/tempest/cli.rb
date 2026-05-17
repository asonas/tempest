require_relative "../tempest"
require_relative "commands/tui"

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
        stdout.puts Tempest::Commands::Tui.help_text
        return 0
      end

      Tempest::Commands::Tui.call(
        argv: argv, env: env, stdout: stdout, stderr: stderr, stdin: stdin,
        session_factory: session_factory, store: store,
      )
    end

    VALID_FEED_MODES = Tempest::Commands::Tui::VALID_FEED_MODES

    # Forwarding delegates — keep Tempest::CLI.* callable so existing tests
    # do not need modification. All logic lives in Tempest::Commands::Tui.

    def sign_in(env, stdout, stdin, session_factory, store:)
      Tempest::Commands::Tui.sign_in(env, stdout, stdin, session_factory, store: store)
    end

    def nil_if_empty(value)
      Tempest::Commands::Tui.nil_if_empty(value)
    end

    def build_reauth(env, stdout, stdin, session_factory)
      Tempest::Commands::Tui.build_reauth(env, stdout, stdin, session_factory)
    end

    def create_with_2fa(config, env, stdout, stdin, session_factory)
      Tempest::Commands::Tui.create_with_2fa(config, env, stdout, stdin, session_factory)
    end

    def stream_default_on?(argv, env)
      Tempest::Commands::Tui.stream_default_on?(argv, env)
    end

    def cursor_store(env)
      Tempest::Commands::Tui.cursor_store(env)
    end

    def build_debug_logger(env)
      Tempest::Commands::Tui.build_debug_logger(env)
    end

    def watchdog_options(env)
      Tempest::Commands::Tui.watchdog_options(env)
    end

    def timeline_store(env)
      Tempest::Commands::Tui.timeline_store(env)
    end

    def avatar_cache_dir(env)
      Tempest::Commands::Tui.avatar_cache_dir(env)
    end

    def opener_for(env:, system_proc: Kernel.method(:system))
      Tempest::Commands::Tui.opener_for(env: env, system_proc: system_proc)
    end

    def feed_mode(argv:, env: {})
      Tempest::Commands::Tui.feed_mode(argv: argv, env: env)
    end

    def build_subscription(mode:, session:, client:, handle_resolver: nil, stdout: nil)
      Tempest::Commands::Tui.build_subscription(
        mode: mode, session: session, client: client,
        handle_resolver: handle_resolver, stdout: stdout,
      )
    end

    def attach_store(session, store, identifier)
      Tempest::Commands::Tui.attach_store(session, store, identifier)
    end

    def help_text
      Tempest::Commands::Tui.help_text
    end
  end
end
