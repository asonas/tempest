require_relative "../commands"
require_relative "../session_store"
require_relative "../config"
require_relative "../repl/formatter"

module Tempest
  module Commands
    module Base
      module_function

      VALID_FORMATS = %i[line json raw].freeze

      # Loads the cached session and refreshes it. Returns the session on
      # success. On failure (no cache, refresh rejected) writes a single
      # human-readable line to stderr and returns nil; callers translate the
      # nil into exit code 3.
      def authenticate(env:, stderr:, store: nil)
        store ||= Tempest::SessionStore.new(path: Tempest::SessionStore.default_path(env))
        session = store.load(identifier: env["TEMPEST_IDENTIFIER"], pds_host: env["TEMPEST_PDS_HOST"])
        if session.nil?
          stderr.puts "error: no cached session — run `tempest tui` once to sign in"
          return nil
        end
        session.on_change = ->(s) { store.save(s, identifier: s.identifier) }
        begin
          session.refresh!
        rescue Tempest::Error => e
          stderr.puts "error: cached session refresh failed: #{e.message}"
          return nil
        end
        session
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
