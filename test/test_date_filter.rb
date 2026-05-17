require_relative "test_helper"
require "time"
require "tempest/date_filter"

class TestDateFilter < Minitest::Test
  def test_today_returns_local_midnight
    now = Time.local(2026, 5, 17, 14, 30, 0)
    parsed = Tempest::DateFilter.parse("today", now: now)
    assert_equal Time.local(2026, 5, 17, 0, 0, 0), parsed
  end

  def test_yesterday_returns_previous_local_midnight
    now = Time.local(2026, 5, 17, 14, 30, 0)
    assert_equal Time.local(2026, 5, 16, 0, 0, 0),
                 Tempest::DateFilter.parse("yesterday", now: now)
  end

  def test_Nd_returns_n_days_before_local_midnight
    now = Time.local(2026, 5, 17, 14, 30, 0)
    assert_equal Time.local(2026, 5, 10, 0, 0, 0),
                 Tempest::DateFilter.parse("7d", now: now)
  end

  def test_iso_date_only_returns_local_midnight
    assert_equal Time.local(2026, 5, 17, 0, 0, 0),
                 Tempest::DateFilter.parse("2026-05-17")
  end

  def test_iso_datetime_with_offset_returns_exact_time
    expected = Time.iso8601("2026-05-17T05:00:00Z")
    assert_equal expected, Tempest::DateFilter.parse("2026-05-17T05:00:00Z")
  end

  def test_unknown_format_raises_argument_error
    assert_raises(ArgumentError) { Tempest::DateFilter.parse("never") }
  end

  def test_filter_drops_posts_outside_since_until
    posts = [
      { created_at: "2026-05-15T09:00:00Z" },
      { created_at: "2026-05-17T01:00:00Z" },
      { created_at: "2026-05-18T01:00:00Z" },
    ]
    kept = Tempest::DateFilter.filter(
      posts,
      since: Time.iso8601("2026-05-17T00:00:00Z"),
      until_at: Time.iso8601("2026-05-18T00:00:00Z"),
    )
    assert_equal ["2026-05-17T01:00:00Z"], kept.map { |p| p[:created_at] }
  end
end
