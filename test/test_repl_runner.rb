require_relative "test_helper"
require "stringio"
require "tempest/post"
require "tempest/repl/runner"

class TestREPLRunner < Minitest::Test
  class FakeSession
    attr_reader :did, :handle

    def initialize
      @did = "did:plc:abc"
      @handle = "asonas.bsky.social"
    end
  end

  class FakeXRPCClient
    attr_reader :timeline_calls, :post_calls

    def initialize
      @timeline_calls = 0
      @post_calls = []
    end

    def get(nsid, query: nil)
      @timeline_calls += 1 if nsid == "app.bsky.feed.getTimeline"
      {
        "feed" => [
          {
            "post" => {
              "uri" => "at://did:plc:a/app.bsky.feed.post/1",
              "cid" => "bafy",
              "author" => { "handle" => "alice.bsky.social" },
              "record" => { "text" => "hi", "createdAt" => "2026-05-15T00:00:00.000Z" },
            },
          },
        ],
      }
    end

    def post(nsid, body:)
      @post_calls << [nsid, body]
      { "uri" => "at://did:plc:abc/app.bsky.feed.post/new", "cid" => "bafy" }
    end
  end

  def setup
    @session = FakeSession.new
    @client = FakeXRPCClient.new
    @output = StringIO.new
  end

  def run_with(inputs)
    runner = Tempest::REPL::Runner.new(
      session: @session,
      client: @client,
      input: StubReader.new(inputs),
      output: @output,
    )
    runner.run
    @output.string
  end

  class StubReader
    def initialize(lines)
      @lines = lines.dup
    end

    def readline(_prompt)
      @lines.shift
    end
  end

  def test_quit_command_exits_loop
    out = run_with([":quit"])
    assert_match(/bye/i, out)
  end

  def test_nil_input_treated_as_quit
    out = run_with([nil])
    assert_match(/bye/i, out)
  end

  def test_timeline_command_fetches_and_prints_posts
    out = run_with([":timeline", ":quit"])
    assert_equal 1, @client.timeline_calls
    assert_match(/@alice\.bsky\.social: hi/, out)
  end

  def test_plain_input_creates_post
    out = run_with(["Hello, Bluesky!", ":quit"])
    assert_equal 1, @client.post_calls.length
    nsid, body = @client.post_calls.first
    assert_equal "com.atproto.repo.createRecord", nsid
    assert_equal "did:plc:abc", body[:repo]
    assert_equal "Hello, Bluesky!", body[:record]["text"]
    assert_match(/posted/i, out)
  end

  def test_help_command_lists_available_commands
    out = run_with([":help", ":quit"])
    assert_match(/:timeline/, out)
    assert_match(/:quit/, out)
  end

  def test_unknown_command_prints_message
    out = run_with([":nope", ":quit"])
    assert_match(/unknown.*nope/i, out)
  end

  def test_blank_input_is_ignored
    out_before = @output.string.dup
    out = run_with(["", "   ", ":quit"])
    refute_match(/posted/i, out.sub(out_before, ""))
  end

  class FakeStreamManager
    attr_reader :start_calls, :stop_calls
    attr_accessor :running

    def initialize
      @start_calls = 0
      @stop_calls = 0
      @running = false
      @on_event = nil
    end

    def start(&block)
      @start_calls += 1
      @running = true
      @on_event = block
    end

    def stop
      @stop_calls += 1
      @running = false
    end

    def running?
      @running
    end

    def emit(event)
      @on_event&.call(event)
    end
  end

  def run_with_stream(inputs, stream_manager:)
    runner = Tempest::REPL::Runner.new(
      session: @session,
      client: @client,
      input: StubReader.new(inputs),
      output: @output,
      stream_manager: stream_manager,
    )
    runner.run
    @output.string
  end

  def test_stream_on_starts_manager
    stream = FakeStreamManager.new
    out = run_with_stream([":stream on", ":quit"], stream_manager: stream)

    assert_equal 1, stream.start_calls
    assert_equal 1, stream.stop_calls # :quit triggers stop
    assert_match(/stream on/, out)
  end

  def test_stream_off_stops_manager
    stream = FakeStreamManager.new
    stream.running = true
    out = run_with_stream([":stream off", ":quit"], stream_manager: stream)

    assert stream.stop_calls >= 1
    assert_match(/stream off/, out)
  end

  def test_stream_on_when_already_running_says_so
    stream = FakeStreamManager.new
    stream.running = true
    out = run_with_stream([":stream on", ":quit"], stream_manager: stream)

    assert_equal 0, stream.start_calls
    assert_match(/already on/, out)
  end

  def test_stream_event_printed_via_formatter
    require "tempest/jetstream/decoder"
    event = Tempest::Jetstream::Event.new(
      kind: :commit, did: "did:plc:x", time_us: 1,
      collection: "app.bsky.feed.post", operation: :create,
      rkey: "r", cid: nil, text: "hello stream", created_at: "2026-01-01T00:00:00Z",
    )

    stream = FakeStreamManager.new
    runner = Tempest::REPL::Runner.new(
      session: @session,
      client: @client,
      input: StubReader.new([":stream on", ":quit"]),
      output: @output,
      stream_manager: stream,
    )

    # Drive the run loop; :stream on registers callback, then we emit, then :quit
    inputs = [":stream on", ":quit"]
    reader = Class.new do
      def initialize(inputs, stream, event)
        @inputs = inputs.dup
        @stream = stream
        @event = event
      end

      def readline(_prompt)
        line = @inputs.shift
        # After the stream is enabled, push an event before processing :quit
        @stream.emit(@event) if line == ":quit"
        line
      end
    end.new(inputs, stream, event)

    Tempest::REPL::Runner.new(
      session: @session,
      client: @client,
      input: reader,
      output: @output,
      stream_manager: stream,
    ).run

    assert_match(/<did:plc:x>: hello stream/, @output.string)
  end

  # Drives the runner with a reader that injects stream callbacks between input
  # reads, so we can simulate the manager pushing StreamStatus events at well-
  # defined moments.
  class EmittingReader
    def initialize(steps)
      @steps = steps.dup
    end

    def readline(_prompt)
      step = @steps.shift
      return nil if step.nil?
      step[:emit]&.call
      step[:line]
    end
  end

  class MultiPostXRPCClient
    attr_reader :timeline_calls

    def initialize
      @timeline_calls = 0
    end

    def get(nsid, query: nil)
      raise "unexpected nsid #{nsid}" unless nsid == "app.bsky.feed.getTimeline"
      @timeline_calls += 1
      {
        "feed" => [
          {"post" => post_view("z", "newer", "2026-05-15T02:00:00.000Z")},
          {"post" => post_view("y", "middle", "2026-05-15T01:00:00.000Z")},
          {"post" => post_view("x", "older",  "2026-05-15T00:00:00.000Z")},
        ],
      }
    end

    def post(*) ; {} ; end

    private

    def post_view(rkey, text, created_at)
      {
        "uri" => "at://did:plc:a/app.bsky.feed.post/#{rkey}",
        "cid" => "bafy#{rkey}",
        "author" => { "handle" => "alice.bsky.social" },
        "record" => { "text" => text, "createdAt" => created_at },
      }
    end
  end

  def test_gapped_status_triggers_timeline_backfill_in_chronological_order
    require "tempest/jetstream/stream_manager"
    stream = FakeStreamManager.new
    client = MultiPostXRPCClient.new

    steps = [
      { line: ":stream on" },
      {
        emit: -> {
          stream.emit(Tempest::Jetstream::StreamStatus.new(
            state: :gapped, since: Time.utc(2026, 5, 14, 12, 0, 0),
          ))
        },
        line: ":quit",
      },
    ]

    runner = Tempest::REPL::Runner.new(
      session: @session,
      client: client,
      input: EmittingReader.new(steps),
      output: @output,
      stream_manager: stream,
    )
    runner.run

    out = @output.string
    assert_equal 1, client.timeline_calls
    assert_match(/^-- fetching timeline/, out)

    # Posts must appear oldest-first below the status line.
    older_idx  = out.index("older")
    middle_idx = out.index("middle")
    newer_idx  = out.index("newer")
    refute_nil older_idx
    refute_nil middle_idx
    refute_nil newer_idx
    assert older_idx < middle_idx, "older should appear before middle"
    assert middle_idx < newer_idx, "middle should appear before newer"
  end

  class FakeTimelineStore
    attr_accessor :stored, :saved_payloads

    def initialize(stored: nil)
      @stored = stored
      @saved_payloads = []
    end

    def load
      @stored
    end

    def save(posts:, at: Time.now)
      @saved_payloads << { posts: posts, at: at }
    end
  end

  def test_bootstrap_timeline_prints_cached_posts_in_chronological_order
    cached = [
      Tempest::Post.new(
        uri: "at://did:plc:a/app.bsky.feed.post/old1",
        cid: "bafy-old1", handle: "alice.bsky.social", display_name: nil,
        text: "older", created_at: "2026-05-14T00:00:00.000Z",
      ),
      Tempest::Post.new(
        uri: "at://did:plc:a/app.bsky.feed.post/old2",
        cid: "bafy-old2", handle: "alice.bsky.social", display_name: nil,
        text: "newer", created_at: "2026-05-14T01:00:00.000Z",
      ),
    ]
    store = FakeTimelineStore.new(stored: { posts: cached, saved_at: Time.utc(2026, 5, 14, 1, 5, 0) })
    client = MultiPostXRPCClient.new

    runner = Tempest::REPL::Runner.new(
      session: @session,
      client: client,
      input: StubReader.new([":quit"]),
      output: @output,
      timeline_store: store,
    )
    runner.bootstrap_timeline
    runner.run

    out = @output.string
    older_idx = out.index("older")
    newer_idx = out.index("newer")
    refute_nil older_idx
    refute_nil newer_idx
    assert older_idx < newer_idx, "cached posts should appear oldest-first"
  end

  # The first cached uri matches MultiPostXRPCClient's "x" post so the fetch
  # response overlaps the cache by one entry. Only the strictly newer posts
  # should be appended.
  def test_bootstrap_timeline_fetches_and_prints_only_new_posts
    cached = [
      Tempest::Post.new(
        uri: "at://did:plc:a/app.bsky.feed.post/x",
        cid: "bafyx", handle: "alice.bsky.social", display_name: nil,
        text: "older", created_at: "2026-05-15T00:00:00.000Z",
      ),
    ]
    store = FakeTimelineStore.new(stored: { posts: cached, saved_at: Time.utc(2026, 5, 15, 0, 5, 0) })
    client = MultiPostXRPCClient.new

    runner = Tempest::REPL::Runner.new(
      session: @session,
      client: client,
      input: StubReader.new([":quit"]),
      output: @output,
      timeline_store: store,
    )
    runner.bootstrap_timeline
    runner.run

    out = @output.string
    assert_equal 1, client.timeline_calls

    # "older" appears once (from cache), "middle" and "newer" appear once each (new).
    assert_equal 1, out.scan("older").length
    assert_equal 1, out.scan("middle").length
    assert_equal 1, out.scan("newer").length

    older_idx  = out.index("older")
    middle_idx = out.index("middle")
    newer_idx  = out.index("newer")
    assert older_idx < middle_idx, "cached posts must precede new posts"
    assert middle_idx < newer_idx, "new posts must be chronological"
  end

  def test_bootstrap_timeline_saves_merged_posts_in_chronological_order
    cached = [
      Tempest::Post.new(
        uri: "at://did:plc:a/app.bsky.feed.post/x",
        cid: "bafyx", handle: "alice.bsky.social", display_name: nil,
        text: "older", created_at: "2026-05-15T00:00:00.000Z",
      ),
    ]
    store = FakeTimelineStore.new(stored: { posts: cached, saved_at: Time.utc(2026, 5, 15, 0, 5, 0) })
    client = MultiPostXRPCClient.new

    runner = Tempest::REPL::Runner.new(
      session: @session,
      client: client,
      input: StubReader.new([":quit"]),
      output: @output,
      timeline_store: store,
    )
    runner.bootstrap_timeline

    assert_equal 1, store.saved_payloads.length
    saved = store.saved_payloads.first[:posts]
    assert_equal ["older", "middle", "newer"], saved.map(&:text)
  end

  class FailingTimelineClient
    def get(*) ; raise Tempest::Error, "boom" ; end
    def post(*) ; raise "unused" ; end
  end

  def test_bootstrap_timeline_prints_error_on_fetch_failure_and_keeps_cache
    cached = [
      Tempest::Post.new(
        uri: "at://did:plc:a/app.bsky.feed.post/x",
        cid: "bafyx", handle: "alice.bsky.social", display_name: nil,
        text: "older", created_at: "2026-05-15T00:00:00.000Z",
      ),
    ]
    store = FakeTimelineStore.new(stored: { posts: cached, saved_at: Time.utc(2026, 5, 15, 0, 5, 0) })

    runner = Tempest::REPL::Runner.new(
      session: @session,
      client: FailingTimelineClient.new,
      input: StubReader.new([":quit"]),
      output: @output,
      timeline_store: store,
    )
    runner.bootstrap_timeline

    out = @output.string
    assert_match(/@alice\.bsky\.social: older/, out)
    assert_match(/^-- timeline fetch failed: boom/, out)
    assert_equal 0, store.saved_payloads.length
  end

  def test_timeline_command_saves_fetched_posts_when_store_present
    store = FakeTimelineStore.new
    client = MultiPostXRPCClient.new

    runner = Tempest::REPL::Runner.new(
      session: @session,
      client: client,
      input: StubReader.new([":timeline", ":quit"]),
      output: @output,
      timeline_store: store,
    )
    runner.run

    assert_equal 1, store.saved_payloads.length
    assert_equal ["older", "middle", "newer"], store.saved_payloads.first[:posts].map(&:text)
  end

  def test_stream_like_event_rendered_with_target
    require "tempest/jetstream/decoder"
    event = Tempest::Jetstream::Event.new(
      kind: :commit, did: "did:plc:actor", time_us: 1,
      collection: "app.bsky.feed.like", operation: :create,
      rkey: "lk", cid: nil, text: nil, created_at: nil,
      subject_uri: "at://did:plc:target/app.bsky.feed.post/abc",
    )

    stream = FakeStreamManager.new
    reader_class = Class.new do
      def initialize(inputs, stream, event)
        @inputs = inputs.dup
        @stream = stream
        @event = event
      end

      def readline(_prompt)
        line = @inputs.shift
        @stream.emit(@event) if line == ":quit"
        line
      end
    end

    Tempest::REPL::Runner.new(
      session: @session,
      client: @client,
      input: reader_class.new([":stream on", ":quit"], stream, event),
      output: @output,
      stream_manager: stream,
    ).run

    assert_match(/<did:plc:actor>: liked <did:plc:target>'s post/, @output.string)
  end

  def test_stream_repost_event_rendered_with_target
    require "tempest/jetstream/decoder"
    event = Tempest::Jetstream::Event.new(
      kind: :commit, did: "did:plc:actor", time_us: 1,
      collection: "app.bsky.feed.repost", operation: :create,
      rkey: "rp", cid: nil, text: nil, created_at: nil,
      subject_uri: "at://did:plc:target/app.bsky.feed.post/xyz",
    )

    stream = FakeStreamManager.new
    reader_class = Class.new do
      def initialize(inputs, stream, event)
        @inputs = inputs.dup
        @stream = stream
        @event = event
      end

      def readline(_prompt)
        line = @inputs.shift
        @stream.emit(@event) if line == ":quit"
        line
      end
    end

    Tempest::REPL::Runner.new(
      session: @session,
      client: @client,
      input: reader_class.new([":stream on", ":quit"], stream, event),
      output: @output,
      stream_manager: stream,
    ).run

    assert_match(/<did:plc:actor>: reposted <did:plc:target>'s post/, @output.string)
  end

  def test_stream_status_rendered_with_double_dash_prefix
    require "tempest/jetstream/stream_manager"
    stream = FakeStreamManager.new

    steps = [
      { line: ":stream on" },
      {
        emit: -> {
          stream.emit(Tempest::Jetstream::StreamStatus.new(
            state: :disconnected, reason: :closed,
          ))
          stream.emit(Tempest::Jetstream::StreamStatus.new(state: :reconnecting))
          stream.emit(Tempest::Jetstream::StreamStatus.new(state: :live))
        },
        line: ":quit",
      },
    ]

    runner = Tempest::REPL::Runner.new(
      session: @session,
      client: @client,
      input: EmittingReader.new(steps),
      output: @output,
      stream_manager: stream,
    )
    runner.run

    out = @output.string
    assert_match(/^-- disconnected/, out)
    assert_match(/^-- reconnecting/, out)
    assert_match(/^-- live/, out)
  end
end
