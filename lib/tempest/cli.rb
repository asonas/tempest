require_relative "../tempest"
require_relative "commands/tui"
require_relative "commands/base"
require_relative "commands/whoami"
require_relative "commands/post"
require_relative "commands/feed"
require_relative "commands/follow"
require_relative "commands/login"
require_relative "commands/accounts"
require_relative "debug_log"
require_relative "deprecated_envs"
require_relative "xrpc_client"

module Tempest
  module CLI
    SUBCOMMANDS = %w[tui post feed whoami follow accounts login].freeze

    module_function

    # Pulls `--user <name>` / `--user=<name>` out of argv and returns
    # `[user_or_nil, remaining_argv]`. Raises ArgumentError when the flag is
    # present but the value is missing or empty. Multiple occurrences: last one
    # wins.
    def extract_user(argv)
      user = nil
      remaining = []
      i = 0
      while i < argv.length
        arg = argv[i]
        if arg == "--user"
          nxt = argv[i + 1]
          if nxt.nil? || nxt.empty? || nxt.start_with?("-")
            raise ArgumentError, "--user requires a value"
          end
          user = nxt
          i += 2
        elsif arg.start_with?("--user=")
          value = arg["--user=".length..]
          raise ArgumentError, "--user requires a value" if value.nil? || value.empty?
          user = value
          i += 1
        else
          remaining << arg
          i += 1
        end
      end
      [user, remaining]
    end

    def run(argv: ARGV, env: ENV, stdout: $stdout, stderr: $stderr, stdin: $stdin,
            session_factory: Tempest::Session.method(:create),
            store: nil)
      begin
        user, argv = extract_user(argv)
      rescue ArgumentError => e
        stderr.puts "error: #{e.message}"
        return 64
      end

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
        Tempest::DeprecatedEnvs.warn_if_set(env: env, stderr: stderr)
        rest = (head == "tui") ? argv.drop(1) : argv
        Tempest::Commands::Tui.call(
          argv: rest, env: env, stdout: stdout, stderr: stderr, stdin: stdin,
          session_factory: session_factory, store: store, user: user,
        )
      when head == "login"
        if user
          stderr.puts "error: --user is not supported for `login`"
          return 64
        end
        logger = build_subcommand_logger(env)
        begin
          Tempest::Commands::Login.call(
            argv: argv.drop(1), env: env, stdout: stdout, stderr: stderr, stdin: stdin,
            session_factory: session_factory, logger: logger,
          )
        rescue Tempest::Error, ArgumentError => e
          stderr.puts "error: #{e.message}"
          Tempest::Commands::Base.exit_code_for(e)
        end
      when head == "accounts"
        if user
          stderr.puts "error: --user is not supported for `accounts`"
          return 64
        end
        logger = build_subcommand_logger(env)
        begin
          Tempest::Commands::Accounts.call(
            argv: argv.drop(1), env: env, stdout: stdout, stderr: stderr, logger: logger,
          )
        rescue Tempest::Error, ArgumentError => e
          stderr.puts "error: #{e.message}"
          Tempest::Commands::Base.exit_code_for(e)
        end
      when SUBCOMMANDS.include?(head)
        Tempest::DeprecatedEnvs.warn_if_set(env: env, stderr: stderr)
        logger = build_subcommand_logger(env)
        begin
          dispatch_subcommand(head, argv, env: env, stdout: stdout, stderr: stderr, stdin: stdin, user: user, logger: logger)
        rescue Tempest::Error, ArgumentError => e
          stderr.puts "error: #{e.message}"
          Tempest::Commands::Base.exit_code_for(e)
        end
      else
        stderr.puts "unknown command: #{head.inspect}"
        64
      end
    end

    # Build the info-level logger used by non-TUI subcommands so that
    # account/login/migration events still reach info.log. Always non-verbose
    # (no `debug:` flag), distinct from the TUI's `--debug` channel.
    def build_subcommand_logger(env)
      Tempest::DebugLog.build(env: env, debug: false)
    end

    def dispatch_subcommand(head, argv, env:, stdout:, stderr:, stdin:, user: nil, logger: nil)
      session, code = Tempest::Commands::Base.authenticate_with_code(
        env: env, stderr: stderr, user: user, logger: logger,
      )
      return code if session.nil?
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
