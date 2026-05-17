require_relative "../commands"

module Tempest
  module Commands
    module Whoami
      module_function

      def call(argv:, session:, stdout:, stderr:)
        if argv.include?("--did") && argv.include?("--handle")
          stderr.puts "error: --did and --handle are mutually exclusive"
          return 64
        end
        if argv.include?("--did")
          stdout.puts session.did
        elsif argv.include?("--handle")
          stdout.puts session.handle
        elsif argv.include?("--json")
          require "json"
          stdout.puts JSON.generate(
            "handle" => session.handle,
            "did" => session.did,
            "pds_host" => session.pds_host,
          )
        else
          stdout.puts "@#{session.handle} (#{session.did})"
        end
        0
      end
    end
  end
end
