require_relative "../tempest"

module Tempest
  # Silences the Ruby 4.x experimental warning fired by `IO::Buffer`. The
  # warning originates in `<internal:io>` but surfaces through async-dns /
  # `resolv.rb` on the Jetstream WebSocket connect path, and the user cannot
  # act on it. Other warnings, including unrelated `IO::Buffer` references,
  # are forwarded to the original `Warning.warn` so genuine signals still
  # reach stderr.
  module WarningFilter
    PATTERN = /IO::Buffer is experimental/

    module_function

    def suppress?(msg)
      return false unless msg.is_a?(String)
      msg.match?(PATTERN)
    end

    def install!
      return if Warning.singleton_class.include?(self)
      Warning.singleton_class.prepend(self)
    end

    def warn(msg, **kwargs)
      return if Tempest::WarningFilter.suppress?(msg)
      super
    end
  end
end
