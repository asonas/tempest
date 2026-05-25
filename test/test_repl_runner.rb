require_relative "test_helper"
require "stringio"
require "tempest/post"
require "tempest/repl/runner"

class TestREPLRunner < Minitest::Test
  class FakeSession
    attr_reader :did, :handle, :replace_calls

    def initialize
      @did = "did:plc:abc"
      @handle = "asonas.bsky.social"
      @replace_calls = []
    end

    def replace_with!(other)
      @replace_calls << other
      @did = other.did
      @handle = other.handle
      self
    end
  end

  class FakeXRPCClient
    attr_reader :timeline_calls, :post_calls

    def initialize
      @timeline_calls = 0
      @post_calls = []
    end

    def get(nsid, query: nil)
      if nsid == "com.atproto.repo.getRecord"
        return {
          "uri" => "at://did:plc:a/app.bsky.feed.post/1",
          "cid" => "bafy",
          "value" => { "$type" => "app.bsky.feed.post", "text" => "hi" },
        }
      end
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

  # `:stream on` after `:stream off` (or `--no-stream` startup) should refresh
  # the timeline once before the live worker resumes. Otherwise the only catch-
  # up path is Jetstream cursor-replay, which can return nothing if events
  # were trimmed or filtered out client-side.
  def test_stream_on_runs_timeline_backfill_before_starting_manager
    stream = FakeStreamManager.new
    out = run_with_stream([":stream on", ":quit"], stream_manager: stream)

    assert_equal 1, stream.start_calls
    assert_equal 1, @client.timeline_calls, "expected getTimeline to fire on :stream on"
    assert_match(/@alice\.bsky\.social: hi/, out, "expected backfilled post to appear")
  end

  # When the stream is already running, `:stream on` is a no-op and must not
  # double-fetch the timeline.
  def test_stream_on_when_already_running_does_not_backfill
    stream = FakeStreamManager.new
    stream.running = true
    run_with_stream([":stream on", ":quit"], stream_manager: stream)

    assert_equal 0, @client.timeline_calls
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
    # `:stream on` itself triggers one backfill, then `:gapped` triggers a
    # second. The second is effectively a no-op print-wise (posts are deduped
    # via @displayed_post_uris), but the getTimeline call still fires.
    assert_equal 2, client.timeline_calls
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

  # Bootstrap fetches getTimeline and prints the posts; if the saved Jetstream
  # cursor is older than those posts, the stream replays the same URIs. The
  # runner must dedupe stream events against what bootstrap already printed.
  def test_stream_post_event_is_deduped_against_bootstrap_timeline
    require "tempest/jetstream/decoder"
    store = FakeTimelineStore.new(stored: nil)
    client = MultiPostXRPCClient.new
    stream = FakeStreamManager.new

    steps = [
      { line: ":stream on" },
      {
        emit: -> {
          # Same URI as the "newer" post printed during bootstrap
          # (at://did:plc:a/app.bsky.feed.post/z).
          stream.emit(Tempest::Jetstream::Event.new(
            kind: :commit, did: "did:plc:a", time_us: 999,
            collection: "app.bsky.feed.post", operation: :create,
            rkey: "z", cid: "bafyz", text: "newer", created_at: "2026-05-15T02:00:00.000Z",
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
      timeline_store: store,
    )
    runner.bootstrap_timeline
    runner.run

    out = @output.string
    # The "newer" post must appear exactly once (from bootstrap), not again
    # from the replayed stream event.
    assert_equal 1, out.scan("newer").length
  end

  # When the watchdog force-reconnects on a quiet stream, Jetstream replays
  # events from the saved cursor. The last event we already rendered will be
  # re-yielded; the runner must dedupe it so it does not print again.
  def test_stream_post_event_is_deduped_when_replayed_after_reconnect
    require "tempest/jetstream/decoder"
    stream = FakeStreamManager.new

    event = Tempest::Jetstream::Event.new(
      kind: :commit, did: "did:plc:a", time_us: 1000,
      collection: "app.bsky.feed.post", operation: :create,
      rkey: "z", cid: "bafyz", text: "only once", created_at: "2026-05-15T02:00:00.000Z",
    )

    steps = [
      { line: ":stream on" },
      {
        emit: -> {
          stream.emit(event)
          stream.emit(Tempest::Jetstream::StreamError.new(StandardError.new("forced reconnect")))
          stream.emit(Tempest::Jetstream::StreamStatus.new(state: :disconnected, reason: :error))
          stream.emit(Tempest::Jetstream::StreamStatus.new(state: :reconnecting))
          stream.emit(Tempest::Jetstream::StreamStatus.new(state: :live))
          stream.emit(event)
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

    assert_equal 1, @output.string.scan("only once").length
  end

  # A stream event whose URI was not printed during bootstrap should still
  # be rendered normally.
  def test_stream_post_event_not_in_bootstrap_is_still_printed
    require "tempest/jetstream/decoder"
    store = FakeTimelineStore.new(stored: nil)
    client = MultiPostXRPCClient.new
    stream = FakeStreamManager.new

    steps = [
      { line: ":stream on" },
      {
        emit: -> {
          stream.emit(Tempest::Jetstream::Event.new(
            kind: :commit, did: "did:plc:b", time_us: 1000,
            collection: "app.bsky.feed.post", operation: :create,
            rkey: "fresh", cid: "bafyfresh", text: "brand new", created_at: "2026-05-15T03:00:00.000Z",
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
      timeline_store: store,
    )
    runner.bootstrap_timeline
    runner.run

    assert_match(/brand new/, @output.string)
  end

  def test_reply_to_unknown_id_prints_unknown_id_and_does_not_post
    out = run_with(["$AA hello", ":quit"])
    assert_match(/unknown id: \$AA/, out)
    assert_empty @client.post_calls
  end

  def test_reply_with_empty_body_prints_usage_and_does_not_post
    # :timeline assigns $AA to the lone returned post; "$AA" with no body errors.
    out = run_with([":timeline", "$AA", ":quit"])
    assert_match(/usage: \$XX <text>/, out)
    assert_empty @client.post_calls
  end

  def test_reply_happy_path_posts_body_verbatim_and_sets_reply_target
    out = run_with([":timeline", "$AA hello back", ":quit"])
    assert_equal 1, @client.post_calls.length
    nsid, body = @client.post_calls.first
    assert_equal "com.atproto.repo.createRecord", nsid
    assert_equal "hello back", body[:record]["text"]
    assert_equal(
      "at://did:plc:a/app.bsky.feed.post/1",
      body[:record]["reply"]["parent"]["uri"],
    )
    assert_equal "bafy", body[:record]["reply"]["parent"]["cid"]
    assert_match(/posted: at:\/\//, out)
  end

  class RecordingOpener
    attr_reader :calls

    def initialize(result: true)
      @calls = []
      @result = result
    end

    def call(url)
      @calls << url
      @result
    end
  end

  def run_with_opener(inputs, opener:)
    runner = Tempest::REPL::Runner.new(
      session: @session,
      client: @client,
      input: StubReader.new(inputs),
      output: @output,
      opener: opener,
    )
    runner.run
    @output.string
  end

  def test_open_unknown_id_prints_unknown_id_and_does_not_invoke_opener
    opener = RecordingOpener.new
    out = run_with_opener([":open $LA", ":quit"], opener: opener)
    assert_match(/unknown id: \$LA/, out)
    assert_empty opener.calls
  end

  def test_open_without_id_prints_usage
    opener = RecordingOpener.new
    out = run_with_opener([":open", ":quit"], opener: opener)
    assert_match(/usage: :open \$XX or \$LX/, out)
    assert_empty opener.calls
  end

  def test_open_with_post_id_opens_bsky_app_url_for_assigned_post
    client = OpenableTimelineClient.new
    opener = RecordingOpener.new
    runner = Tempest::REPL::Runner.new(
      session: @session, client: client,
      input: StubReader.new([":timeline", ":open $AA", ":quit"]),
      output: @output, opener: opener,
    )
    runner.run

    assert_equal ["https://bsky.app/profile/alice.bsky.social/post/p"], opener.calls
  end

  def test_open_with_post_id_falls_back_to_did_when_handle_is_missing
    handleless = Tempest::Post.new(
      uri: "at://did:plc:nobody/app.bsky.feed.post/abc",
      cid: "bafy",
      handle: nil,
      display_name: nil,
      text: "hi",
      created_at: nil,
    )
    registry = Tempest::REPL::Registry.new
    var = registry.assign_post(handleless)
    opener = RecordingOpener.new
    runner = Tempest::REPL::Runner.new(
      session: @session, client: @client,
      input: StubReader.new([":open #{var}", ":quit"]),
      output: @output, opener: opener, registry: registry,
    )
    runner.run

    assert_equal ["https://bsky.app/profile/did:plc:nobody/post/abc"], opener.calls
  end

  def test_help_lists_open_with_post_id_form
    out = run_with([":help", ":quit"])
    assert_match(/:open \$XX/, out)
  end

  def test_open_calls_opener_with_registered_url
    client = OpenableTimelineClient.new
    opener = RecordingOpener.new
    runner = Tempest::REPL::Runner.new(
      session: @session, client: client,
      input: StubReader.new([":timeline", ":open $LA", ":quit"]),
      output: @output, opener: opener,
    )
    runner.run

    assert_equal ["https://example.com/page"], opener.calls
  end

  def test_open_prints_failure_when_opener_returns_false
    client = OpenableTimelineClient.new
    opener = RecordingOpener.new(result: false)
    runner = Tempest::REPL::Runner.new(
      session: @session, client: client,
      input: StubReader.new([":timeline", ":open $LA", ":quit"]),
      output: @output, opener: opener,
    )
    runner.run

    assert_match(%r{error: failed to open https://example\.com/page}, @output.string)
  end

  class OpenableTimelineClient
    def get(nsid, query: nil)
      raise "unexpected nsid #{nsid}" unless nsid == "app.bsky.feed.getTimeline"
      {
        "feed" => [
          {
            "post" => {
              "uri" => "at://did:plc:a/app.bsky.feed.post/p",
              "cid" => "bafy",
              "author" => { "handle" => "alice.bsky.social" },
              "record" => {
                "text" => "check https://example.com/page",
                "createdAt" => "2026-05-15T00:00:00.000Z",
              },
            },
          },
        ],
      }
    end
    def post(*) ; {} ; end
  end

  class FacetTimelineClient
    TRUNCATED = "www.kelloggs.com/ja-jp/produc...".freeze
    REAL_URL = "https://www.kelloggs.com/ja-jp/products/some-cereal".freeze

    def get(nsid, query: nil)
      raise "unexpected nsid #{nsid}" unless nsid == "app.bsky.feed.getTimeline"
      text = "イライラする #{TRUNCATED} 続き"
      byte_start = "イライラする ".bytesize
      byte_end = byte_start + TRUNCATED.bytesize
      {
        "feed" => [
          {
            "post" => {
              "uri" => "at://did:plc:a/app.bsky.feed.post/k",
              "cid" => "bafy",
              "author" => { "handle" => "alice.bsky.social" },
              "record" => {
                "text" => text,
                "createdAt" => "2026-05-15T00:00:00.000Z",
                "facets" => [
                  {
                    "index" => { "byteStart" => byte_start, "byteEnd" => byte_end },
                    "features" => [
                      { "$type" => "app.bsky.richtext.facet#link", "uri" => REAL_URL },
                    ],
                  },
                ],
              },
            },
          },
        ],
      }
    end
    def post(*) ; {} ; end
  end

  def test_relogin_command_replaces_session_via_reauth_proc
    new_session = FakeSession.new
    reauth = -> { new_session }

    runner = Tempest::REPL::Runner.new(
      session: @session,
      client: @client,
      input: StubReader.new([":relogin", ":quit"]),
      output: @output,
      reauth: reauth,
    )
    runner.run

    assert_equal [new_session], @session.replace_calls
    assert_match(/signed in/i, @output.string)
  end

  def test_relogin_command_prints_error_when_reauth_fails
    reauth = -> { raise Tempest::AuthenticationError.new("nope", code: "AuthenticationRequired") }

    runner = Tempest::REPL::Runner.new(
      session: @session,
      client: @client,
      input: StubReader.new([":relogin", ":quit"]),
      output: @output,
      reauth: reauth,
    )
    runner.run

    assert_empty @session.replace_calls
    assert_match(/relogin failed.*nope/i, @output.string)
  end

  def test_relogin_command_without_reauth_proc_explains_unavailability
    out = run_with([":relogin", ":quit"])
    assert_match(/relogin is not available/i, out)
  end

  class AuthExpiringClient
    def get(*) ; raise "unused" ; end

    def post(*)
      raise Tempest::AuthenticationError.new(
        "refreshSession failed (400): Token has been revoked",
        code: "ExpiredToken",
      )
    end
  end

  def test_post_authentication_error_hints_to_relogin
    runner = Tempest::REPL::Runner.new(
      session: @session,
      client: AuthExpiringClient.new,
      input: StubReader.new(["hi", ":quit"]),
      output: @output,
    )
    runner.run

    out = @output.string
    assert_match(/error:.*revoked/i, out)
    assert_match(/:relogin/, out)
  end

  def test_open_with_facet_url_passes_real_uri_not_truncated
    client = FacetTimelineClient.new
    opener = RecordingOpener.new
    runner = Tempest::REPL::Runner.new(
      session: @session, client: client,
      input: StubReader.new([":timeline", ":open $LA", ":quit"]),
      output: @output, opener: opener,
    )
    runner.run

    assert_equal [FacetTimelineClient::REAL_URL], opener.calls
    assert_match(/\[www\.kelloggs\.com \$LA\]/, @output.string)
  end

  def test_fav_to_unknown_id_prints_unknown_id_and_does_not_post
    out = run_with([":fav $ZZ", ":quit"])
    assert_match(/unknown id: \$ZZ/, out)
    assert_empty @client.post_calls
  end

  def test_fav_without_arg_prints_usage_and_does_not_post
    out = run_with([":fav", ":quit"])
    assert_match(/usage: :fav \$XX/, out)
    assert_empty @client.post_calls
  end

  def test_fav_happy_path_creates_like_record_pointing_at_assigned_post
    out = run_with([":timeline", ":fav $AA", ":quit"])

    assert_equal 1, @client.post_calls.length
    nsid, body = @client.post_calls.first
    assert_equal "com.atproto.repo.createRecord", nsid
    assert_equal "did:plc:abc", body[:repo]
    assert_equal "app.bsky.feed.like", body[:collection]
    record = body[:record]
    assert_equal "app.bsky.feed.like", record["$type"]
    assert_equal "at://did:plc:a/app.bsky.feed.post/1", record["subject"]["uri"]
    assert_equal "bafy", record["subject"]["cid"]
    assert_match(/liked: at:\/\//, out)
  end

  class FavAuthExpiringClient
    FEED_RESPONSE = {
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
    }.freeze

    def get(_nsid, query: nil)
      FEED_RESPONSE
    end

    def post(*)
      raise Tempest::AuthenticationError.new(
        "refreshSession failed (400): Token has been revoked",
        code: "ExpiredToken",
      )
    end
  end

  def test_fav_authentication_error_hints_to_relogin
    runner = Tempest::REPL::Runner.new(
      session: @session,
      client: FavAuthExpiringClient.new,
      input: StubReader.new([":timeline", ":fav $AA", ":quit"]),
      output: @output,
    )
    runner.run

    out = @output.string
    assert_match(/error:.*revoked/i, out)
    assert_match(/:relogin/, out)
  end

  class FavGenericErrorClient
    FEED_RESPONSE = {
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
    }.freeze

    def get(_nsid, query: nil)
      FEED_RESPONSE
    end

    def post(*)
      raise Tempest::Error.new("boom")
    end
  end

  def test_fav_generic_error_is_reported_without_relogin_hint
    runner = Tempest::REPL::Runner.new(
      session: @session,
      client: FavGenericErrorClient.new,
      input: StubReader.new([":timeline", ":fav $AA", ":quit"]),
      output: @output,
    )
    runner.run

    out = @output.string
    assert_match(/error: boom/, out)
    refute_match(/:relogin/, out)
  end

  def test_help_lists_fav_command
    out = run_with([":help", ":quit"])
    assert_match(/:fav \$XX/, out)
  end

  # Simple StringIO that also tracks Screen.suspend/resume calls so we can
  # assert the editor suspend/resume sequence around :compose.
  class SuspendableOutput < StringIO
    attr_reader :events

    def initialize
      super()
      @events = []
    end

    def suspend
      @events << :suspend
    end

    def resume
      @events << :resume
    end
  end

  def run_with_compose(inputs, compose:, output: nil)
    @output = output if output
    runner = Tempest::REPL::Runner.new(
      session: @session,
      client: @client,
      input: StubReader.new(inputs),
      output: @output,
      compose: compose,
    )
    runner.run
    @output.string
  end

  def test_compose_command_creates_post_with_body_from_editor
    compose = ->(*) { [:ok, "from editor!"] }
    out = run_with_compose([":compose", ":quit"], compose: compose)

    assert_equal 1, @client.post_calls.length
    body = @client.post_calls.first.last
    assert_equal "from editor!", body[:record]["text"]
    assert_match(/posted/i, out)
  end

  def test_compose_command_suspends_and_resumes_screen
    output = SuspendableOutput.new
    capture_when_called = nil
    compose = ->(*) {
      capture_when_called = output.events.dup
      [:ok, "ok"]
    }
    run_with_compose([":compose", ":quit"], compose: compose, output: output)

    # disable must run before the editor invocation,
    # enable must run after.
    assert_equal [:suspend], capture_when_called,
      "Screen must be suspended before the editor runs"
    assert_equal [:suspend, :resume], output.events,
      "Screen must be resumed after the editor returns"
  end

  def test_compose_command_with_empty_result_does_not_post
    compose = ->(*) { [:empty, nil] }
    out = run_with_compose([":compose", ":quit"], compose: compose)

    assert_empty @client.post_calls
    assert_match(/cancelled/i, out)
  end

  def test_compose_command_when_editor_fails_reports_error
    compose = ->(*) { [:editor_failed, nil] }
    out = run_with_compose([":compose", ":quit"], compose: compose)

    assert_empty @client.post_calls
    assert_match(/editor.*non-zero/i, out)
  end

  def test_compose_command_re_enables_screen_even_if_compose_raises
    output = SuspendableOutput.new
    compose = ->(*) { raise "boom" }

    assert_raises(RuntimeError) do
      run_with_compose([":compose"], compose: compose, output: output)
    end

    assert_equal [:suspend, :resume], output.events,
      "Screen must be resumed even when Compose.run raises"
  end

  def test_help_lists_compose_command
    out = run_with([":help", ":quit"])
    assert_match(/:compose/, out)
  end
end
