require "time"

module Tempest
  module DateFilter
    module_function

    def parse(raw, now: Time.now)
      case raw
      when "today"     then local_midnight(now)
      when "yesterday" then local_midnight(now) - 86_400
      when /\A(\d+)d\z/ then local_midnight(now) - (Regexp.last_match(1).to_i * 86_400)
      when /\A\d{4}-\d{2}-\d{2}\z/ then Time.local(*raw.split("-").map(&:to_i))
      else
        Time.iso8601(raw)
      end
    rescue ArgumentError
      raise ArgumentError, "invalid date: #{raw.inspect}"
    end

    def filter(posts, since: nil, until_at: nil)
      posts.select do |p|
        ts = p[:created_at] || p["created_at"]
        next false if ts.nil?
        t = Time.iso8601(ts)
        (since.nil? || t >= since) && (until_at.nil? || t < until_at)
      end
    end

    def local_midnight(now)
      l = now.respond_to?(:localtime) ? now.localtime : now
      Time.local(l.year, l.month, l.day, 0, 0, 0)
    end
  end
end
