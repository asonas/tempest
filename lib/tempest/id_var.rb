require_relative "../tempest"

module Tempest
  # Earthquake-style identifier ring. Each generator owns a fixed list of
  # slots (e.g. "AA".."ZZ" = 676 slots). New ids consume the next slot;
  # when the ring wraps the previous tenant of the recycled slot is
  # evicted from both the forward (id => var) and reverse (var => id)
  # tables so callers never see a stale mapping.
  #
  # Not thread-safe. The REPL renders posts on a single thread (either
  # the main REPL thread or behind Screen's mutex) so external
  # serialization is sufficient.
  class IdVar
    def initialize(range:, prefix: "$")
      @slots = range.to_a
      raise ArgumentError, "range produced no slots" if @slots.empty?
      @prefix = prefix
      @cursor = -1
      @forward = {} # id => var
      @reverse = {} # var => id
    end

    def generate(id)
      return @forward[id] if @forward.key?(id)
      @cursor = (@cursor + 1) % @slots.length
      var = "#{@prefix}#{@slots[@cursor]}"
      evict(var)
      @forward[id] = var
      @reverse[var] = id
      var
    end

    def lookup(var)
      @reverse[var]
    end

    private

    def evict(var)
      old_id = @reverse.delete(var)
      @forward.delete(old_id) if old_id
    end
  end
end
