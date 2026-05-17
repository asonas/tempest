require_relative "../tempest"

module Tempest
  # Typed representations of app.bsky.richtext.facet entries attached to a
  # post record. `byte_start` / `byte_end` are UTF-8 byte offsets into the
  # post text (NOT character offsets). We only model the `#link` feature for
  # now; `#mention` and `#tag` features are dropped at parse time.
  module Facet
    Link = Data.define(:byte_start, :byte_end, :uri)

    module_function

    # Parse a raw facets array from a Bluesky record into typed entries.
    # Unknown / unsupported feature types are silently dropped.
    def parse(raw)
      return [] unless raw.is_a?(Array)

      raw.flat_map do |facet|
        next [] unless facet.is_a?(Hash)
        index = facet["index"] || {}
        byte_start = index["byteStart"]
        byte_end = index["byteEnd"]
        next [] unless byte_start.is_a?(Integer) && byte_end.is_a?(Integer)

        features = facet["features"]
        next [] unless features.is_a?(Array)

        features.filter_map do |feature|
          next nil unless feature.is_a?(Hash)
          case feature["$type"]
          when "app.bsky.richtext.facet#link"
            uri = feature["uri"]
            next nil unless uri.is_a?(String) && !uri.empty?
            Link.new(byte_start: byte_start, byte_end: byte_end, uri: uri)
          end
        end
      end
    end
  end
end
