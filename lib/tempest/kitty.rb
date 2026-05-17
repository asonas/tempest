require "base64"

require_relative "../tempest"

module Tempest
  # Encodes an image as a Kitty graphics protocol "transmit and display"
  # escape sequence. Pure transformation: no I/O beyond optionally reading
  # the bytes from a path. Output is meant to be inlined into a single
  # terminal row when called with the defaults (rows: 1, cols: 2).
  #
  # Protocol reference:
  #   https://sw.kovidgoyal.net/kitty/graphics-protocol/
  #
  # Key control opcodes used:
  #   a=T   transmit and immediately display
  #   f=100 source bytes are PNG
  #   r=N   render at N terminal rows
  #   c=N   render at N terminal columns
  #   C=1   do not advance the cursor (image is drawn at the current cell,
  #         the cursor stays where it was)
  #   m=0/1 multi-chunk marker: 1 = more chunks follow, 0 = final chunk
  module Kitty
    CHUNK_BYTES = 4096

    module_function

    def inline(png, rows: 1, cols: 2)
      bytes = png.is_a?(String) && File.file?(png) ? File.binread(png) : png
      data = Base64.strict_encode64(bytes)
      out = String.new
      pos = 0
      first = true
      while pos < data.bytesize
        piece = data.byteslice(pos, CHUNK_BYTES)
        pos += CHUNK_BYTES
        more = pos < data.bytesize ? 1 : 0
        controls = if first
          "a=T,f=100,r=#{rows},c=#{cols},C=1,m=#{more}"
        else
          "m=#{more}"
        end
        out << "\e_G#{controls};#{piece}\e\\"
        first = false
      end
      out
    end
  end
end
