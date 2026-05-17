require "base64"
require "tempfile"

require_relative "test_helper"
require "tempest/kitty"

class TestKitty < Minitest::Test
  # Minimal PNG magic bytes — enough for the encoder to round-trip, even though
  # they are not a valid image. Tempest::Kitty is a pure byte-to-escape
  # transformer; it must not parse or validate the PNG.
  PNG_MAGIC = "\x89PNG\r\n\x1A\n".b.freeze

  def test_inline_returns_kitty_escape_string
    out = Tempest::Kitty.inline(PNG_MAGIC)

    assert out.start_with?("\e_G"), "expected output to start with ESC _ G, got: #{out.inspect}"
    assert out.end_with?("\e\\"), "expected output to end with ESC \\, got: #{out.inspect}"
  end

  def test_inline_first_chunk_carries_default_control_opcodes
    out = Tempest::Kitty.inline(PNG_MAGIC)
    controls = control_segment(out)

    assert_includes controls, "a=T"
    assert_includes controls, "f=100"
    assert_includes controls, "r=1"
    assert_includes controls, "c=2"
    assert_includes controls, "C=1"
  end

  def test_inline_round_trips_bytes_as_base64_payload
    bytes = (PNG_MAGIC + ("payload data " * 5)).b
    out = Tempest::Kitty.inline(bytes)

    decoded = data_segments(out).map { |b64| Base64.strict_decode64(b64) }.join
    assert_equal bytes, decoded
  end

  # The Kitty graphics protocol caps each chunk's base64 payload at 4096
  # bytes. Anything larger must be split, with m=1 on every chunk but the
  # last, m=0 on the last, and only the first chunk carrying full controls.
  def test_inline_splits_large_payloads_into_multiple_chunks
    bytes = (PNG_MAGIC + ("x" * 6000)).b
    out = Tempest::Kitty.inline(bytes)

    chunks = chunks_of(out)
    assert_operator chunks.length, :>, 1,
      "expected payload to be split; got #{chunks.length} chunk(s) for #{bytes.bytesize} bytes"

    first_controls = chunks.first[:controls]
    assert_includes first_controls, "a=T"
    assert_includes first_controls, "f=100"
    assert_includes first_controls, "m=1"

    chunks[1..-2].each do |chunk|
      assert_equal ["m=1"], chunk[:controls],
        "intermediate chunks should carry only m=1, got #{chunk[:controls].inspect}"
    end

    last = chunks.last
    assert_equal ["m=0"], last[:controls],
      "final chunk should carry only m=0, got #{last[:controls].inspect}"

    chunks[0..-2].each do |chunk|
      assert_operator chunk[:data].bytesize, :<=, 4096
    end

    decoded = chunks.map { |c| Base64.strict_decode64(c[:data]) }.join
    assert_equal bytes, decoded
  end

  def test_inline_honors_rows_and_cols_overrides
    out = Tempest::Kitty.inline(PNG_MAGIC, rows: 2, cols: 4)
    controls = control_segment(out)

    assert_includes controls, "r=2"
    assert_includes controls, "c=4"
    refute_includes controls, "r=1"
    refute_includes controls, "c=2"
  end

  def test_inline_reads_bytes_when_given_an_existing_file_path
    bytes = (PNG_MAGIC + "from disk").b
    file = Tempfile.new(["kitty-probe", ".png"], binmode: true)
    file.write(bytes)
    file.close

    from_path = Tempest::Kitty.inline(file.path)
    from_bytes = Tempest::Kitty.inline(bytes)
    assert_equal from_bytes, from_path
  ensure
    file&.close
    file&.unlink
  end

  private

  # Parse out the comma-separated control opcodes from the first chunk:
  #   "\e_G<controls>;<data>\e\\..." -> ["a=T", "f=100", ...]
  def control_segment(escape)
    raise "missing ESC _ G prefix: #{escape.inspect}" unless escape.start_with?("\e_G")
    rest = escape.byteslice(3..)
    semi = rest.index(";")
    raise "missing ; separator: #{escape.inspect}" if semi.nil?
    rest.byteslice(0, semi).split(",")
  end

  # Return the base64 data payloads from each "\e_G<controls>;<data>\e\\" chunk
  # in escape, in order. Chunks without a ";" (controls-only) yield nothing.
  def data_segments(escape)
    chunks_of(escape).map { |c| c[:data] }
  end

  # Decompose a Kitty escape stream into per-chunk hashes:
  #   [{ controls: ["a=T", "m=1", ...], data: "<base64>" }, ...]
  def chunks_of(escape)
    chunks = []
    scanner = escape.dup
    while (start = scanner.index("\e_G"))
      tail = scanner.index("\e\\", start)
      raise "unterminated chunk: #{scanner.inspect}" if tail.nil?
      body = scanner.byteslice(start + 3, tail - (start + 3))
      semi = body.index(";")
      controls = (semi ? body.byteslice(0, semi) : body).split(",")
      data = semi ? body.byteslice(semi + 1..) : ""
      chunks << { controls: controls, data: data }
      scanner = scanner.byteslice(tail + 2..)
    end
    chunks
  end
end
