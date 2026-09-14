require "test_helper"

class Game::Damage::PieceSetTest < ActiveSupport::TestCase
  test "a fresh set holds nothing" do
    set = Game::Damage::PieceSet.new(20)

    assert_equal 0, set.count
    refute set.include?(0)
    assert_empty set.to_a
  end

  # Bit 0, bit 7 and bit 8 are the boundaries worth naming: the first bit of the first
  # byte, the last bit of the first byte, and the first bit of the second. An off-by-one
  # in the byte/bit split shows up at exactly one of these and nowhere else.
  test "the byte and bit boundaries land where they should" do
    set = Game::Damage::PieceSet.new(20)
    [ 0, 7, 8 ].each { |index| set.add(index) }

    assert_equal [ 0, 7, 8 ], set.to_a
    assert_equal "\x81\x01\x00".b, set.to_blob
  end

  test "adding twice reports the second as no change" do
    set = Game::Damage::PieceSet.new(20)

    assert set.add(3), "the first add is a change"
    refute set.add(3), "the second is not"
    assert_equal 1, set.count
  end

  # A piece count that is not a multiple of eight leaves spare bits in the last byte. The
  # last real index has to be reachable and the spare bits have to stay clear.
  test "the last bit of a set that does not fill its final byte" do
    set = Game::Damage::PieceSet.new(20)
    set.add(19)

    assert_equal 3, set.to_blob.bytesize
    assert_equal [ 19 ], set.to_a
    assert_equal "\x00\x00\x08".b, set.to_blob
  end

  test "a blob round trips" do
    set = Game::Damage::PieceSet.new(1454)
    [ 0, 1, 63, 64, 1453 ].each { |index| set.add(index) }

    restored = Game::Damage::PieceSet.from_blob(set.to_blob, 1454)

    assert_equal set.to_a, restored.to_a
    assert_equal set.count, restored.count
  end

  # Without this a malformed index writes into the bytes of a neighbouring object's bitset.
  test "an index outside the object is refused" do
    set = Game::Damage::PieceSet.new(20)

    assert_raises(ArgumentError) { set.add(20) }
    assert_raises(ArgumentError) { set.add(-1) }
    assert_raises(ArgumentError) { set.include?(20) }
  end

  test "a short blob is padded rather than trusted" do
    restored = Game::Damage::PieceSet.from_blob("\xFF".b, 20)

    assert_equal (0..7).to_a, restored.to_a
    assert_equal 3, restored.to_blob.bytesize
  end
end
