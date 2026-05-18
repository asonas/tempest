require "tempfile"

require_relative "../../tempest"

module Tempest
  module REPL
    # Opens `$VISUAL` / `$EDITOR` on a scratch file so the user can compose a
    # multi-line post in their normal editor, the same pattern `git commit`
    # uses. Returns one of the status tuples below; the caller (typically
    # `Runner#handle_compose`) maps each to a user-facing line and, when
    # `:ok`, forwards the body to `Post.create`.
    #
    # Return values:
    #   [:ok, body]            successful compose; body is non-empty
    #   [:empty, nil]          user saved an empty body — treat as cancellation
    #   [:editor_failed, nil]  the editor subprocess returned a non-zero status
    #
    # Lines beginning with `#` are stripped from the file before posting (so we
    # can pre-populate the file with instructions a la `git commit`'s template).
    module Compose
      TEMPLATE = <<~EOT.freeze

        # Compose your Bluesky post above this line.
        # Lines starting with `#` and surrounding whitespace are stripped.
        # Save with an empty body (or quit without changes) to cancel.
      EOT

      module_function

      def run(env: ENV, runner: Kernel.method(:system),
              tempfile_factory: ->(suffix) { Tempfile.new(["tempest-compose-", suffix]) })
        editor = pick_editor(env)

        file = tempfile_factory.call(".txt")
        path = file.path
        begin
          file.write(TEMPLATE)
          file.flush
          file.close

          ok = runner.call(editor, path)
          return [:editor_failed, nil] unless ok

          body = parse(File.read(path))
          return [:empty, nil] if body.empty?
          [:ok, body]
        ensure
          begin
            file.unlink
          rescue StandardError
            # File may already be gone (e.g. editor moved it); best-effort.
          end
        end
      end

      # Editor resolution order, matching git's convention: $VISUAL, then
      # $EDITOR, then "vi" as a POSIX-mandated last resort. The fallback means
      # we never need to surface a "no editor" error to the user; if even vi
      # cannot be exec'd, `Kernel.system` returns false and the call surfaces
      # as :editor_failed.
      def pick_editor(env)
        candidate = env["VISUAL"]
        candidate = env["EDITOR"] if candidate.nil? || candidate.strip.empty?
        candidate = "vi" if candidate.nil? || candidate.strip.empty?
        candidate
      end

      def parse(content)
        content
          .each_line
          .reject { |line| line.start_with?("#") }
          .join
          .strip
      end
    end
  end
end
