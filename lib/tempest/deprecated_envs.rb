require_relative "../tempest"

module Tempest
  # Emits a one-line stderr warning per deprecated environment variable that is
  # still set. Called from non-interactive command entry points (`tui`, `post`,
  # `feed`, `whoami`); intentionally skipped by `login` and `accounts` so their
  # interactive prompts and structured output stay clean.
  module DeprecatedEnvs
    NAMES = %w[TEMPEST_SESSION_PATH TEMPEST_CURSOR_PATH TEMPEST_TIMELINE_PATH TEMPEST_PDS_HOST].freeze

    module_function

    def warn_if_set(env:, stderr:)
      NAMES.each do |name|
        value = env[name]
        next if value.nil? || value.empty?
        stderr.puts "warning: #{name} is no longer honored; tempest uses accounts/<did>/ layout"
      end
    end
  end
end
