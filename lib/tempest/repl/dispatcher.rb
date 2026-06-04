require_relative "../../tempest"

module Tempest
  module REPL
    Command = Data.define(:name, :args)

    class Dispatcher
      # The colon commands whose arguments are split on whitespace. This is not
      # the full set of commands: the bare `$XX <text>` reply form and `:quote`
      # (which keeps a free-text body) are parsed separately in #dispatch, so
      # they are intentionally absent here despite being valid commands.
      KNOWN_COMMANDS = %i[timeline quit help stream open relogin fav compose].freeze
      DOLLAR_ID = /\A\$[A-Z]{2}\z/.freeze

      def dispatch(input)
        return Command.new(name: :quit, args: []) if input.nil?

        stripped = input.strip
        return Command.new(name: :noop, args: []) if stripped.empty?

        if stripped.start_with?(":")
          # `:quote $XX <text>` carries a free-text body, so split off the id
          # and keep the remainder intact (mirroring the `$XX <text>` reply
          # form) instead of tokenizing the whole tail on whitespace.
          if (m = stripped.match(/\A:quote(?:\s+(.*))?\z/m))
            var, body = m[1].to_s.strip.split(/\s+/, 2)
            return Command.new(name: :quote, args: [var.to_s, body.to_s])
          end

          name, *rest = stripped[1..].split(/\s+/)
          symbol = name.to_sym
          if KNOWN_COMMANDS.include?(symbol)
            Command.new(name: symbol, args: rest)
          else
            Command.new(name: :unknown, args: [name])
          end
        else
          head, tail = stripped.split(/\s+/, 2)
          if DOLLAR_ID.match?(head)
            Command.new(name: :reply, args: [head, tail.to_s])
          else
            Command.new(name: :post, args: [stripped])
          end
        end
      end
    end
  end
end
