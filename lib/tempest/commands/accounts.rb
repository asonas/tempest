require "json"

require_relative "../commands"
require_relative "../accounts_store"
require_relative "../accounts_migration"

module Tempest
  module Commands
    # `tempest accounts list` / `tempest accounts set-default <handle|did>`.
    module Accounts
      module_function

      def call(argv:, env:, stdout:, stderr:, logger: nil)
        Tempest::AccountsMigration.run(env: env, stderr: stderr, logger: logger)
        sub = argv.first

        case sub
        when "list"
          list(argv.drop(1), env: env, stdout: stdout, stderr: stderr, logger: logger)
        when "set-default"
          set_default(argv.drop(1), env: env, stdout: stdout, stderr: stderr, logger: logger)
        when nil
          stdout.puts "usage: tempest accounts list|set-default ..."
          64
        else
          stderr.puts "error: unknown accounts subcommand: #{sub}"
          64
        end
      end

      def list(argv, env:, stdout:, stderr:, logger: nil)
        format = "line"
        argv.each do |arg|
          if (m = arg.match(/\A--format=(\S+)\z/))
            format = m[1]
          end
        end
        unless %w[line json].include?(format)
          stderr.puts "error: invalid --format: #{format.inspect}"
          return 64
        end

        store = Tempest::AccountsStore.new(env: env, logger: logger)

        if store.accounts.empty?
          if format == "json"
            stdout.puts JSON.generate("default" => nil, "accounts" => [])
          else
            stdout.puts "no accounts — run `tempest login` to add one"
          end
          return 0
        end

        case format
        when "json"
          payload = {
            "default" => store.default,
            "accounts" => store.accounts.map { |a|
              {
                "did" => a.did,
                "handle" => a.handle,
                "identifier" => a.identifier,
                "pds_host" => a.pds_host,
                "added_at" => a.added_at.utc.iso8601(6),
              }
            },
          }
          stdout.puts JSON.generate(payload)
        when "line"
          store.accounts.each do |a|
            marker = (a.did == store.default) ? "* " : "  "
            stdout.puts "#{marker}@#{a.handle} (#{a.did}) #{a.pds_host}  added #{a.added_at.utc.strftime("%Y-%m-%d")}"
          end
        end
        0
      end

      def set_default(argv, env:, stdout:, stderr:, logger: nil)
        value = argv.first
        if value.nil? || value.empty?
          stderr.puts "usage: tempest accounts set-default <handle|did>"
          return 64
        end

        store = Tempest::AccountsStore.new(env: env, logger: logger)
        target = store.resolve(value)
        if target.nil?
          stderr.puts "error: unknown user: #{value} (run `tempest accounts list` to see known accounts)"
          return 2
        end

        store.set_default(target.did)
        stdout.puts "default account set to @#{target.handle} (#{target.did})"
        0
      end
    end
  end
end
