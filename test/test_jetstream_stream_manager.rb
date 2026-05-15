require_relative "test_helper"
require "tempest/jetstream/stream_manager"
require "tempest/jetstream/client"

class TestJetstreamStreamManager < Minitest::Test
  class FakeClient
    attr_reader :started

    def initialize(events: [], block_on_iteration: false)
      @events = events
      @block_on_iteration = block_on_iteration
      @started = 0
    end

    def each_event
      @started += 1
      @events.each { |e| yield e }
      sleep 0.5 if @block_on_iteration
    end
  end

  def test_start_invokes_callback_for_each_event
    event = Tempest::Jetstream::Event.new(
      kind: :commit, did: "did:plc:x", time_us: 1,
      collection: "app.bsky.feed.post", operation: :create,
      rkey: "r", cid: nil, text: "hello", created_at: "2026-01-01T00:00:00Z",
    )
    client = FakeClient.new(events: [event])
    received = Queue.new
    manager = Tempest::Jetstream::StreamManager.new(client: client)

    manager.start { |e| received << e }

    captured = received.pop
    assert_equal "hello", captured.text
    manager.stop
  end

  def test_running_reflects_state
    client = FakeClient.new(block_on_iteration: true)
    manager = Tempest::Jetstream::StreamManager.new(client: client)
    refute manager.running?

    manager.start { |_| }
    # wait until worker boots
    50.times do
      break if manager.running?
      sleep 0.005
    end
    assert manager.running?

    manager.stop
    refute manager.running?
  end

  def test_double_start_is_idempotent
    client = FakeClient.new(block_on_iteration: true)
    manager = Tempest::Jetstream::StreamManager.new(client: client)

    manager.start { |_| }
    50.times { break if client.started == 1; sleep 0.005 }
    manager.start { |_| }
    50.times { sleep 0.005 } # give second start a chance to spawn a worker if buggy

    assert_equal 1, client.started
    manager.stop
  end
end
