require "test_helper"

class Game::Terrain::HeightsCodecTest < ActiveSupport::TestCase
  Codec = Game::Terrain::HeightsCodec

  test "heights round trip to the centimetre" do
    metres = [ 0.0, 1.23, -4.56, 12.0, 40.07 ]
    base = Codec.base_for(metres)

    assert_equal metres, Codec.unpack(Codec.pack(metres, base), base)
  end

  test "a sample is two bytes" do
    metres = Array.new(9, 3.0)
    blob = Codec.pack(metres, Codec.base_for(metres))

    assert_equal 18, blob.bytesize
  end

  # The browser decodes this as one Int16Array construction, which assumes little-endian
  # and a signed 16-bit type. Pin both, because getting either wrong produces terrain that
  # is merely strange rather than obviously broken.
  test "packs signed little-endian 16-bit" do
    blob = Codec.pack([ 1.0 ], 0)

    assert_equal "\x64\x00".b, blob
    assert_equal "\x9C\xFF".b, Codec.pack([ -1.0 ], 0)
  end

  test "the base centres the range rather than starting at one end" do
    # 100m of relief. Centred, that is +/-50m of offset; measured from the bottom it would
    # be 0..100m, which throws away half the available range for nothing.
    metres = [ 0.0, 100.0 ]

    assert_equal 5_000, Codec.base_for(metres)
  end

  test "absolute elevation costs no precision" do
    # Quoted against a national datum: tens of metres above zero everywhere, with only a
    # couple of metres of actual relief.
    metres = [ 22.70, 23.15, 24.00 ]
    base = Codec.base_for(metres)

    assert_equal metres, Codec.unpack(Codec.pack(metres, base), base)
  end

  # Clamping would flatten a peak silently, and both the physics and the render mesh would
  # agree with each other while disagreeing with the source. Better to fail loudly.
  test "a height outside the representable range raises rather than clamping" do
    assert_raises(Codec::RangeError) { Codec.pack([ 400.0 ], 0) }
    assert_raises(Codec::RangeError) { Codec.pack([ -400.0 ], 0) }
  end

  test "relief a tile could plausibly hold is fine" do
    metres = [ -150.0, 0.0, 150.0 ]
    base = Codec.base_for(metres)

    assert_equal metres, Codec.unpack(Codec.pack(metres, base), base)
  end

  test "bounds report the encoded extremes" do
    assert_equal [ -456, 1_200 ], Codec.bounds_cm([ 0.0, -4.56, 12.0 ])
  end
end
