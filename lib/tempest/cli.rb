require_relative "../tempest"
require_relative "config"
require_relative "session"
require_relative "xrpc_client"
require_relative "repl/runner"

module Tempest
  module CLI
    module_function

    def run(argv: ARGV, env: ENV, stdout: $stdout, stderr: $stderr, stdin: $stdin)
      if argv.include?("--version") || argv.include?("-v")
        stdout.puts "tempest #{Tempest::VERSION}"
        return 0
      end

      if argv.include?("--help") || argv.include?("-h")
        stdout.puts help_text
        return 0
      end

      config = Tempest::Config.from_env(env)
      session = Tempest::Session.create(config)
      client = Tempest::XRPCClient.new(session)
      input = RelineReader.new

      stdout.puts "tempest #{Tempest::VERSION} — signed in as @#{session.handle}"
      stdout.puts "Type :help for commands, :quit to exit."

      Tempest::REPL::Runner.new(
        session: session,
        client: client,
        input: input,
        output: stdout,
      ).run
      0
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

    def help_text
      <<~HELP
        Usage: tempest [options]

        Options:
          -h, --help     Show this help
          -v, --version  Show version

        Environment:
          TEMPEST_IDENTIFIER     Your handle (e.g. asonas.bsky.social)
          TEMPEST_APP_PASSWORD   An app password generated in Bluesky settings
          TEMPEST_PDS_HOST       Override PDS host (default: https://bsky.social)
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
