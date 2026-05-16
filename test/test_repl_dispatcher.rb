require_relative "test_helper"
require "tempest/repl/dispatcher"

class TestREPLDispatcher < Minitest::Test
  def setup
    @dispatcher = Tempest::REPL::Dispatcher.new
  end

  def test_colon_timeline_returns_timeline_command
    cmd = @dispatcher.dispatch(":timeline")
    assert_equal :timeline, cmd.name
    assert_empty cmd.args
  end

  def test_colon_quit_returns_quit_command
    cmd = @dispatcher.dispatch(":quit")
    assert_equal :quit, cmd.name
  end

  def test_colon_help_returns_help_command
    cmd = @dispatcher.dispatch(":help")
    assert_equal :help, cmd.name
  end

  def test_plain_text_returns_post_command_with_body
    cmd = @dispatcher.dispatch("Hello, Bluesky!")
    assert_equal :post, cmd.name
    assert_equal ["Hello, Bluesky!"], cmd.args
  end

  def test_blank_input_returns_noop
    cmd = @dispatcher.dispatch("   ")
    assert_equal :noop, cmd.name
  end

  def test_nil_input_returns_quit_for_eof
    cmd = @dispatcher.dispatch(nil)
    assert_equal :quit, cmd.name
  end

  def test_unknown_colon_command_returns_unknown
    cmd = @dispatcher.dispatch(":nonexistent")
    assert_equal :unknown, cmd.name
    assert_equal ["nonexistent"], cmd.args
  end

  def test_colon_stream_on_returns_stream_command_with_arg
    cmd = @dispatcher.dispatch(":stream on")
    assert_equal :stream, cmd.name
    assert_equal ["on"], cmd.args
  end

  def test_colon_stream_off_returns_stream_command_with_arg
    cmd = @dispatcher.dispatch(":stream off")
    assert_equal :stream, cmd.name
    assert_equal ["off"], cmd.args
  end

  def test_colon_stream_without_arg_returns_stream_command_with_empty_args
    cmd = @dispatcher.dispatch(":stream")
    assert_equal :stream, cmd.name
    assert_equal [], cmd.args
  end

  def test_dollar_id_with_body_returns_reply_command
    cmd = @dispatcher.dispatch("$AA hello there")
    assert_equal :reply, cmd.name
    assert_equal ["$AA", "hello there"], cmd.args
  end

  def test_dollar_id_with_link_prefix_returns_reply_command
    cmd = @dispatcher.dispatch("$LA hello")
    assert_equal :reply, cmd.name
    assert_equal ["$LA", "hello"], cmd.args
  end

  def test_dollar_id_alone_returns_reply_with_empty_body
    cmd = @dispatcher.dispatch("$AA")
    assert_equal :reply, cmd.name
    assert_equal ["$AA", ""], cmd.args
  end

  def test_colon_open_with_id_returns_open_command
    cmd = @dispatcher.dispatch(":open $LA")
    assert_equal :open, cmd.name
    assert_equal ["$LA"], cmd.args
  end

  def test_colon_open_without_arg_returns_open_command_with_empty_args
    cmd = @dispatcher.dispatch(":open")
    assert_equal :open, cmd.name
    assert_equal [], cmd.args
  end

  def test_dollar_with_digit_is_still_post
    cmd = @dispatcher.dispatch("$5 for coffee")
    assert_equal :post, cmd.name
    assert_equal ["$5 for coffee"], cmd.args
  end

  def test_dollar_id_with_lowercase_is_still_post
    cmd = @dispatcher.dispatch("$aa hello")
    assert_equal :post, cmd.name
    assert_equal ["$aa hello"], cmd.args
  end
end
