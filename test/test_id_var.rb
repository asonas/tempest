require_relative "test_helper"
require "tempest/id_var"

class TestIdVar < Minitest::Test
  def setup
    @gen = Tempest::IdVar.new(range: "AA".."ZZ")
  end

  def test_first_generate_returns_dollar_AA
    assert_equal "$AA", @gen.generate("id-1")
  end

  def test_second_distinct_id_returns_dollar_AB
    @gen.generate("id-1")
    assert_equal "$AB", @gen.generate("id-2")
  end

  def test_generate_is_idempotent_for_same_id
    first = @gen.generate("id-1")
    @gen.generate("id-2")
    assert_equal first, @gen.generate("id-1")
  end

  def test_lookup_returns_the_registered_id
    @gen.generate("id-1")
    assert_equal "id-1", @gen.lookup("$AA")
  end

  def test_lookup_of_unknown_var_returns_nil
    assert_nil @gen.lookup("$AA")
  end

  def test_wrap_around_reuses_first_slot_for_new_id
    gen = Tempest::IdVar.new(range: "LA".."LZ") # 26 slots
    26.times { |i| gen.generate("id-#{i}") }
    overflow = gen.generate("id-26")
    assert_equal "$LA", overflow
  end

  def test_wrap_around_drops_old_reverse_mapping
    gen = Tempest::IdVar.new(range: "LA".."LZ")
    gen.generate("id-old")           # gets "$LA"
    25.times { |i| gen.generate("id-fill-#{i}") } # consumes LB..LZ
    gen.generate("id-new")           # wraps, takes "$LA"
    assert_equal "id-new", gen.lookup("$LA")
  end

  def test_custom_prefix
    gen = Tempest::IdVar.new(range: "A".."C", prefix: "#")
    assert_equal "#A", gen.generate("id-1")
  end
end
