require_relative "test_helper"
require "tmpdir"
require "tempfile"
require "tempest/repl/compose"

class TestREPLCompose < Minitest::Test
  # Capture every call to the injected editor-runner so we can assert on it.
  def fake_runner(behavior: ->(_path) {})
    calls = []
    runner = ->(editor, path) {
      calls << { editor: editor, path: path }
      behavior.call(path)
      true
    }
    [runner, calls]
  end

  def test_returns_ok_with_parsed_body_when_user_writes_text
    runner, calls = fake_runner(behavior: ->(path) {
      File.write(path, "Hello, Bluesky!\n\n# auto-comment\n")
    })

    status, body = Tempest::REPL::Compose.run(env: { "EDITOR" => "vi" }, runner: runner)

    assert_equal :ok, status
    assert_equal "Hello, Bluesky!", body
    assert_equal 1, calls.length
    assert_equal "vi", calls.first[:editor]
    assert_match(/tempest-compose-/, File.basename(calls.first[:path]))
  end

  def test_preserves_internal_newlines_in_body
    runner, _ = fake_runner(behavior: ->(path) {
      File.write(path, "first line\nsecond line\nthird line\n# trailing instructions\n")
    })

    status, body = Tempest::REPL::Compose.run(env: { "EDITOR" => "vi" }, runner: runner)

    assert_equal :ok, status
    assert_equal "first line\nsecond line\nthird line", body
  end

  def test_strips_comment_lines_anywhere_in_the_file
    runner, _ = fake_runner(behavior: ->(path) {
      File.write(path, "# top instructions\nactual body line\n# more comments\nmore body\n")
    })

    status, body = Tempest::REPL::Compose.run(env: { "EDITOR" => "vi" }, runner: runner)

    assert_equal :ok, status
    assert_equal "actual body line\nmore body", body
  end

  def test_returns_empty_when_user_writes_only_comments
    runner, _ = fake_runner(behavior: ->(path) {
      # User exited without removing the template comments.
      File.write(path, "# comment 1\n# comment 2\n\n\n")
    })

    status, body = Tempest::REPL::Compose.run(env: { "EDITOR" => "vi" }, runner: runner)

    assert_equal :empty, status
    assert_nil body
  end

  def test_returns_empty_when_user_writes_only_whitespace
    runner, _ = fake_runner(behavior: ->(path) {
      File.write(path, "   \n\t\n")
    })

    status, body = Tempest::REPL::Compose.run(env: { "EDITOR" => "vi" }, runner: runner)

    assert_equal :empty, status
    assert_nil body
  end

  def test_returns_no_editor_when_env_has_no_editor_variable
    status, body = Tempest::REPL::Compose.run(env: {}, runner: ->(_e, _p) { true })

    assert_equal :no_editor, status
    assert_nil body
  end

  def test_visual_takes_precedence_over_editor
    captured_editor = nil
    runner = ->(editor, path) {
      captured_editor = editor
      File.write(path, "from $VISUAL\n")
      true
    }

    status, body = Tempest::REPL::Compose.run(
      env: { "EDITOR" => "ed", "VISUAL" => "vim" },
      runner: runner,
    )

    assert_equal :ok, status
    assert_equal "from $VISUAL", body
    assert_equal "vim", captured_editor
  end

  def test_returns_editor_failed_when_runner_returns_falsey
    # Simulates the editor exiting non-zero (e.g. user hit :cq in vim).
    runner = ->(_editor, _path) { false }

    status, body = Tempest::REPL::Compose.run(env: { "EDITOR" => "vi" }, runner: runner)

    assert_equal :editor_failed, status
    assert_nil body
  end

  def test_pre_populates_tempfile_with_a_template_for_the_editor
    captured_initial = nil
    runner = ->(_editor, path) {
      captured_initial = File.read(path)
      File.write(path, "body\n")
      true
    }

    Tempest::REPL::Compose.run(env: { "EDITOR" => "vi" }, runner: runner)

    refute_nil captured_initial
    assert_match(/^#/, captured_initial, "expected template to contain at least one comment line")
  end

  def test_deletes_the_tempfile_even_when_runner_raises
    leaked_paths = []
    runner = ->(_editor, path) {
      leaked_paths << path
      raise "editor crashed"
    }

    assert_raises(RuntimeError) do
      Tempest::REPL::Compose.run(env: { "EDITOR" => "vi" }, runner: runner)
    end

    refute_empty leaked_paths
    refute File.exist?(leaked_paths.first), "tempfile must be cleaned up even on runner failure"
  end
end
