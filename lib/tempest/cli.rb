require_relative "../tempest"
require_relative "commands/tui"
require_relative "commands/base"
require_relative "commands/whoami"
require_relative "commands/post"
require_relative "commands/feed"
require_relative "commands/follow"
require_relative "xrpc_client"

module Tempest
  module CLI
    SUBCOMMANDS = %w[tui post feed whoami follow].freeze

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

      head = argv.first
      case
      when head.nil?, head.start_with?("-"), head == "tui"
        rest = (head == "tui") ? argv.drop(1) : argv
        Tempest::Commands::Tui.call(
          argv: rest, env: env, stdout: stdout, stderr: stderr, stdin: stdin,
          session_factory: session_factory, store: store,
        )
      when SUBCOMMANDS.include?(head)
        begin
          dispatch_subcommand(head, argv, env: env, stdout: stdout, stderr: stderr, stdin: stdin)
        rescue Tempest::Error, ArgumentError => e
          stderr.puts "error: #{e.message}"
          Tempest::Commands::Base.exit_code_for(e)
        end
      else
        stderr.puts "unknown command: #{head.inspect}"
        64
      end
    end

    def dispatch_subcommand(head, argv, env:, stdout:, stderr:, stdin:)
      session = Tempest::Commands::Base.authenticate(env: env, stderr: stderr)
      return 3 if session.nil?
      client = Tempest::XRPCClient.new(session)
      case head
      when "whoami"
        Tempest::Commands::Whoami.call(
          argv: argv.drop(1), session: session,
          stdout: stdout, stderr: stderr,
        )
      when "post"
        Tempest::Commands::Post.call(
          argv: argv.drop(1), session: session, client: client,
          stdout: stdout, stderr: stderr, stdin: stdin,
        )
      when "feed"
        Tempest::Commands::Feed.call(
          argv: argv.drop(1), session: session, client: client,
          stdout: stdout, stderr: stderr,
        )
      when "follow"
        Tempest::Commands::Follow.call(
          argv: argv.drop(1), session: session, client: client,
          stdout: stdout, stderr: stderr,
        )
      end
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

    def build_debug_logger(env, argv: [])
      Tempest::Commands::Tui.build_debug_logger(env, argv: argv)
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
