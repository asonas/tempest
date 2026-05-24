require "tmpdir"

require_relative "test_helper"
require "tempest/avatar_store"

class TestAvatarStore < Minitest::Test
  # FakeClient mirrors the FakeClient pattern from test_handle_resolver.rb so
  # the AvatarStore can be exercised without hitting the network. It records
  # calls for assertions and raises Tempest::APIError for unknown actors.
  class FakeClient
    attr_reader :calls

    def initialize(responses)
      @responses = responses
      @calls = []
    end

    def get(nsid, query: nil)
      @calls << [nsid, query]
      key = query["actor"]
      response = @responses[key]
      raise Tempest::APIError.new(404, { "error" => "NotFound" }) if response.nil?
      response
    end
  end

  # FakeFetcher stubs the HTTP layer; returns [bytes, content_type] tuples.
  class FakeFetcher
    attr_reader :calls

    def initialize(responses)
      @responses = responses
      @calls = []
    end

    def call(url)
      @calls << url
      raise "fake fetcher has no response for #{url.inspect}" unless @responses.key?(url)
      @responses[url]
    end
  end

  # FakeConverter stubs the ImageMagick layer. By default it prefixes the
  # input bytes so tests can assert which bytes ended up on disk.
  class FakeConverter
    attr_reader :calls

    def initialize(transform = nil)
      @transform = transform || ->(bytes, content_type:) { "PNG_FROM_#{content_type}_#{bytes}".b }
      @calls = []
    end

    def call(bytes, content_type:)
      @calls << [bytes, content_type]
      @transform.call(bytes, content_type: content_type)
    end
  end

  def test_path_for_resolves_profile_fetch_and_convert_synchronously
    Dir.mktmpdir do |dir|
      client = FakeClient.new(
        "did:plc:abc" => { "did" => "did:plc:abc", "avatar" => "https://cdn.example/abc/cid1" },
      )
      fetcher = FakeFetcher.new("https://cdn.example/abc/cid1" => ["JPEG".b, "image/jpeg"])
      converter = FakeConverter.new
      store = Tempest::AvatarStore.new(
        client: client, cache_dir: dir, fetcher: fetcher, converter: converter, async: false,
      )

      path = store.path_for("did:plc:abc")

      refute_nil path, "expected path_for to return a string path"
      assert File.exist?(path), "expected #{path.inspect} to exist on disk"
      assert path.start_with?(dir + "/"), "expected #{path.inspect} under #{dir}"
      assert_equal "PNG_FROM_image/jpeg_JPEG", File.binread(path)
    end
  end

  def test_path_for_caches_and_does_not_refetch_for_repeated_calls
    Dir.mktmpdir do |dir|
      client = FakeClient.new(
        "did:plc:abc" => { "avatar" => "https://cdn.example/abc/cid1" },
      )
      fetcher = FakeFetcher.new("https://cdn.example/abc/cid1" => ["bytes".b, "image/jpeg"])
      converter = FakeConverter.new
      store = Tempest::AvatarStore.new(
        client: client, cache_dir: dir, fetcher: fetcher, converter: converter, async: false,
      )

      p1 = store.path_for("did:plc:abc")
      p2 = store.path_for("did:plc:abc")
      p3 = store.path_for("did:plc:abc")

      assert_equal p1, p2
      assert_equal p1, p3
      assert_equal 1, client.calls.length, "getProfile should only fire once"
      assert_equal 1, fetcher.calls.length, "fetcher should only fire once"
      assert_equal 1, converter.calls.length, "converter should only fire once"
    end
  end

  # In async mode the first path_for returns nil (the resolver has to run in
  # the background first), and a follow-up call returns the cached path once
  # the executor has done its work. Tests inject an inline executor so we
  # don't have to wait on real threads.
  def test_async_first_call_returns_nil_then_resolved_path
    Dir.mktmpdir do |dir|
      client = FakeClient.new(
        "did:plc:abc" => { "avatar" => "https://cdn.example/abc/cid1" },
      )
      fetcher = FakeFetcher.new("https://cdn.example/abc/cid1" => ["jpg".b, "image/jpeg"])
      converter = FakeConverter.new
      inline = ->(&block) { block.call }
      store = Tempest::AvatarStore.new(
        client: client, cache_dir: dir, fetcher: fetcher, converter: converter,
        async: true, executor: inline,
      )

      assert_nil store.path_for("did:plc:abc"), "async first call should return nil"

      resolved = store.path_for("did:plc:abc")
      refute_nil resolved, "second call should return the resolved path"
      assert File.exist?(resolved)
      assert_equal 1, client.calls.length, "background resolve should fire only once"
    end
  end

  def test_async_path_for_returns_disk_cached_avatar_immediately
    Dir.mktmpdir do |dir|
      client = FakeClient.new({})
      fetcher = FakeFetcher.new({})
      converter = FakeConverter.new
      cached = File.join(dir, "did_plc_abc__cid1.png")
      File.binwrite(cached, "PNG")
      store = Tempest::AvatarStore.new(
        client: client, cache_dir: dir, fetcher: fetcher, converter: converter, async: true,
      )

      assert_equal cached, store.path_for("did:plc:abc")
      assert_empty client.calls
      assert_empty fetcher.calls
      assert_empty converter.calls
    end
  end

  def test_async_failure_is_negatively_cached_so_executor_does_not_retry
    Dir.mktmpdir do |dir|
      client = FakeClient.new({}) # all lookups fail
      fetcher = FakeFetcher.new({})
      converter = FakeConverter.new
      inline = ->(&block) { block.call }
      store = Tempest::AvatarStore.new(
        client: client, cache_dir: dir, fetcher: fetcher, converter: converter,
        async: true, executor: inline,
      )

      assert_nil store.path_for("did:plc:missing")
      assert_nil store.path_for("did:plc:missing")
      assert_nil store.path_for("did:plc:missing")
      assert_equal 1, client.calls.length, "executor should not retry a known failure"
    end
  end

  def test_seed_lets_callers_inject_a_known_path_without_hitting_http
    Dir.mktmpdir do |dir|
      client = FakeClient.new({})
      fetcher = FakeFetcher.new({})
      converter = FakeConverter.new
      store = Tempest::AvatarStore.new(
        client: client, cache_dir: dir, fetcher: fetcher, converter: converter, async: false,
      )

      seeded = File.join(dir, "seeded.png")
      File.binwrite(seeded, "X")
      store.seed("did:plc:abc", seeded)

      assert_equal seeded, store.path_for("did:plc:abc")
      assert_empty client.calls
      assert_empty fetcher.calls
      assert_empty converter.calls
    end
  end

  def test_path_for_returns_nil_and_negatively_caches_on_get_profile_failure
    Dir.mktmpdir do |dir|
      client = FakeClient.new({}) # any "actor" lookup raises Tempest::APIError
      fetcher = FakeFetcher.new({})
      store = Tempest::AvatarStore.new(
        client: client, cache_dir: dir, fetcher: fetcher, converter: FakeConverter.new, async: false,
      )

      assert_nil store.path_for("did:plc:missing")
      assert_nil store.path_for("did:plc:missing")
      assert_equal 1, client.calls.length, "getProfile should not retry after a known failure"
    end
  end

  def test_path_for_returns_nil_and_negatively_caches_when_converter_raises
    Dir.mktmpdir do |dir|
      client = FakeClient.new(
        "did:plc:abc" => { "avatar" => "https://cdn.example/abc/cid1" },
      )
      fetcher = FakeFetcher.new("https://cdn.example/abc/cid1" => ["jpg".b, "image/jpeg"])
      failing_converter = FakeConverter.new(->(_bytes, content_type:) { raise "boom #{content_type}" })
      store = Tempest::AvatarStore.new(
        client: client, cache_dir: dir, fetcher: fetcher, converter: failing_converter, async: false,
      )

      assert_nil store.path_for("did:plc:abc")
      assert_nil store.path_for("did:plc:abc")
      assert_equal 1, client.calls.length
      assert_equal 1, fetcher.calls.length
      assert_equal 1, failing_converter.calls.length
    end
  end

  def test_path_for_returns_nil_and_negatively_caches_when_profile_has_no_avatar
    Dir.mktmpdir do |dir|
      client = FakeClient.new(
        "did:plc:abc" => { "did" => "did:plc:abc" }, # no "avatar" key
      )
      fetcher = FakeFetcher.new({})
      converter = FakeConverter.new
      store = Tempest::AvatarStore.new(
        client: client, cache_dir: dir, fetcher: fetcher, converter: converter, async: false,
      )

      assert_nil store.path_for("did:plc:abc")
      assert_nil store.path_for("did:plc:abc")
      assert_nil store.path_for("did:plc:abc")
      assert_equal 1, client.calls.length, "getProfile should only fire once even when avatar missing"
      assert_equal 0, fetcher.calls.length, "fetcher should not fire when avatar missing"
      assert_equal 0, converter.calls.length, "converter should not fire when avatar missing"
    end
  end

  # Re-uploading an avatar in Bluesky produces a new blob CID, which shows up
  # as a new tail segment in the avatar URL. The cached file name has to
  # encode both the DID and the CID so a re-upload invalidates the cache.
  def test_cache_file_name_includes_both_did_and_avatar_cid
    Dir.mktmpdir do |dir|
      client = FakeClient.new(
        "did:plc:abc" => { "avatar" => "https://cdn.example/abc/bafkreitest123" },
      )
      fetcher = FakeFetcher.new("https://cdn.example/abc/bafkreitest123" => ["b".b, "image/jpeg"])
      store = Tempest::AvatarStore.new(
        client: client, cache_dir: dir, fetcher: fetcher, converter: FakeConverter.new, async: false,
      )

      path = store.path_for("did:plc:abc")
      name = File.basename(path)

      assert_match(/did[._-]?plc[._-]?abc/, name, "expected sanitized DID in #{name.inspect}")
      assert_includes name, "bafkreitest123"
      assert name.end_with?(".png"), "expected .png suffix in #{name.inspect}"
    end
  end
end

# Exercises Tempest::AvatarStore.default_converter against the real libvips
# backend (no fake injected). Asserts the wire-level PNG header so we are not
# depending on vips to validate vips: anyone with a hex editor can read this.
class TestAvatarStoreDefaultConverter < Minitest::Test
  PNG_SIGNATURE = "\x89PNG\r\n\x1A\n".b.freeze

  def setup
    require "vips"
  end

  def test_converts_jpeg_input_into_128x128_8bit_png
    source = Vips::Image.black(200, 200).bandjoin([10, 220, 30]).cast(:uchar)
    bytes = source.jpegsave_buffer

    png = Tempest::AvatarStore.default_converter.call(bytes, content_type: "image/jpeg")

    width, height, bit_depth, color_type = parse_ihdr(png)
    assert_equal 128, width
    assert_equal 128, height
    assert_equal 8, bit_depth
    assert_includes [2, 6], color_type, "expected RGB(2) or RGBA(6), got #{color_type}"
  end

  def test_center_crops_non_square_input_to_square
    source = Vips::Image.black(400, 100).bandjoin([200, 80, 10]).cast(:uchar)
    bytes = source.pngsave_buffer

    png = Tempest::AvatarStore.default_converter.call(bytes, content_type: "image/png")

    width, height, _bit_depth, _color_type = parse_ihdr(png)
    assert_equal 128, width, "non-square input should still produce square output"
    assert_equal 128, height
  end

  def test_output_starts_with_png_signature
    source = Vips::Image.black(50, 50).bandjoin([0, 0, 255]).cast(:uchar)
    bytes = source.pngsave_buffer

    png = Tempest::AvatarStore.default_converter.call(bytes, content_type: "image/png")

    assert_equal PNG_SIGNATURE, png.byteslice(0, 8)
  end

  private

  # The PNG IHDR chunk lives immediately after the 8-byte signature. Its layout
  # is fixed: 4 bytes length, 4 bytes "IHDR", 4 bytes width (BE), 4 bytes height
  # (BE), 1 byte bit depth, 1 byte color type.
  def parse_ihdr(png)
    raise "missing PNG signature" unless png.start_with?(PNG_SIGNATURE)
    raise "missing IHDR chunk type" unless png.byteslice(12, 4) == "IHDR"
    width = png.byteslice(16, 4).unpack1("N")
    height = png.byteslice(20, 4).unpack1("N")
    bit_depth = png.getbyte(24)
    color_type = png.getbyte(25)
    [width, height, bit_depth, color_type]
  end
end
