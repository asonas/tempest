require_relative "test_helper"
require "stringio"
require "tempest/repl/async_output"

class TestREPLAsyncOutput < Minitest::Test
  def test_puts_clears_current_line_before_writing
    io = StringIO.new
    out = Tempest::REPL::AsyncOutput.new(io)

    out.puts "hello"

    # Carriage return + ANSI erase-to-end-of-line should precede the message.
    assert_match(/\A\r\e\[2K/, io.string)
    assert_includes io.string, "hello\n"
  end

  def test_print_and_flush_are_delegated
    io = StringIO.new
    out = Tempest::REPL::AsyncOutput.new(io)

    out.print "raw"
    out.flush

    assert_equal "raw", io.string
  end

  def test_tty_predicate_delegates
    io = StringIO.new
    out = Tempest::REPL::AsyncOutput.new(io)
    refute out.tty?
  end
end
