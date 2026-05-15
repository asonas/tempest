require_relative "../../tempest"

module Tempest
  module REPL
    Command = Data.define(:name, :args)

    class Dispatcher
      KNOWN_COMMANDS = %i[timeline quit help stream].freeze

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
          Command.new(name: :post, args: [stripped])
        end
      end
    end
  end
end
