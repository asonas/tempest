require_relative "../test_helper"
require "stringio"
require "json"
require "tempest/output/json_writer"

class TestJsonWriter < Minitest::Test
  def test_write_posts_emits_one_json_object_per_line
    io = StringIO.new
    Tempest::Output::JsonWriter.new(io).write_posts([{ a: 1 }, { a: 2 }])
    lines = io.string.lines
    assert_equal 2, lines.length
    assert_equal({ "a" => 1 }, JSON.parse(lines[0]))
    assert_equal({ "a" => 2 }, JSON.parse(lines[1]))
  end

  def test_write_error_writes_single_line_object_with_code_and_message
    io = StringIO.new
    Tempest::Output::JsonWriter.new(io).write_error("oops", code: "api_error")
    assert_equal 1, io.string.lines.length
    payload = JSON.parse(io.string)
    assert_equal "oops", payload["error"]
    assert_equal "api_error", payload["code"]
  end

  def test_write_raw_pretty_prints_payload
    io = StringIO.new
    Tempest::Output::JsonWriter.new(io).write_raw({ "feed" => [{ "post" => { "uri" => "x" } }] })
    parsed = JSON.parse(io.string)
    assert_equal "x", parsed["feed"][0]["post"]["uri"]
    assert io.string.include?("\n  "), "expected pretty-printed JSON to contain indentation"
  end
end
