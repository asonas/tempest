require_relative "../../tempest"

module Tempest
  module REPL
    Command = Data.define(:name, :args)

    class Dispatcher
      KNOWN_COMMANDS = %i[timeline quit help stream open relogin].freeze
      DOLLAR_ID = /\A\$[A-Z]{2}\z/.freeze

      def dispatch(input)
        return Command.new(name: :quit, args: []) if input.nil?

        stripped = input.strip
        return Command.new(name: :noop, args: []) if stripped.empty?

        if stripped.start_with?(":")
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
