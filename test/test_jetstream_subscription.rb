require_relative "test_helper"
require "tempest/jetstream/subscription"

class TestJetstreamSubscription < Minitest::Test
  def follows(*dids)
    dids.map { |d| { did: d, handle: "#{d}.bsky.social" } }
  end

  def test_returns_wanted_dids_when_under_cap
    plan = Tempest::Jetstream::Subscription.build(
      self_did: "did:plc:self",
      follows: follows("did:plc:a", "did:plc:b"),
      cap: 10_000,
    )

    assert_equal "did:plc:self", plan.wanted_dids.first
    assert_includes plan.wanted_dids, "did:plc:a"
    assert_includes plan.wanted_dids, "did:plc:b"
    assert_equal 3, plan.wanted_dids.length
    assert_nil plan.filter, "filter should be nil when wantedDids is respected"
  end

  def test_returns_empty_wanted_dids_and_client_filter_when_above_cap
    big_follows = follows(*(0...10_001).map { |i| "did:plc:f#{i}" })
    plan = Tempest::Jetstream::Subscription.build(
      self_did: "did:plc:self",
      follows: big_follows,
      cap: 10_000,
    )

    assert_equal [], plan.wanted_dids,
      "above cap, the server-side filter is dropped (firehose) and we filter client-side"
    assert plan.filter, "expected a filter predicate when above cap"
    # filter contains self + all follows
    assert plan.filter.call(stub_event("did:plc:self"))
    assert plan.filter.call(stub_event("did:plc:f0"))
    assert plan.filter.call(stub_event("did:plc:f10000"))
    refute plan.filter.call(stub_event("did:plc:stranger"))
  end

  def test_dedupes_self_did_if_already_in_follows
    plan = Tempest::Jetstream::Subscription.build(
      self_did: "did:plc:self",
      follows: follows("did:plc:self", "did:plc:a"),
      cap: 10_000,
    )

    assert_equal ["did:plc:self", "did:plc:a"], plan.wanted_dids,
      "self should appear once even when also listed in follows"
  end

  def test_at_cap_boundary_uses_wanted_dids
    follows_at_limit = follows(*(0...9_999).map { |i| "did:plc:f#{i}" })
    plan = Tempest::Jetstream::Subscription.build(
      self_did: "did:plc:self",
      follows: follows_at_limit,
      cap: 10_000,
    )

    assert_equal 10_000, plan.wanted_dids.length, "self + 9999 follows fits within 10000 cap"
    assert_nil plan.filter
  end

  def stub_event(did)
    Struct.new(:did).new(did)
  end
end
