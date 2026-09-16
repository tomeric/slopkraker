require "test_helper"

class Game::Terrain::TileBuilderTest < ActiveSupport::TestCase
  Builder = Game::Terrain::TileBuilder
  Codec = Game::Terrain::HeightsCodec

  # A 3x3 sample tile at 250m spacing, so one tile is 500m across and the arithmetic can
  # be followed by hand.
  def frame
    @frame ||= Game::Terrain::Frame.new(tile_size: 500, height_step: 250)
  end

  # Row zero is the northern edge. Get this the other way round and every imported map
  # is mirrored north to south, which looks like perfectly good terrain.
  test "walks rows north to south and columns west to east" do
    tile = Builder.encode(frame: frame, tx: 0, tz: 0) { |x, z| x / 100.0 + z / 1000.0 }
    metres = Codec.unpack(tile.heights, tile.base_cm)

    assert_equal [ 0.0, 2.5, 5.0 ], metres[0, 3], "row 0 is z = 0, columns x = 0, 250, 500"
    assert_equal [ 0.5, 3.0, 5.5 ], metres[6, 3], "row 2 is z = 500"
  end

  test "a tile holds one sample per grid point, edges included" do
    tile = Builder.encode(frame: frame, tx: 0, tz: 0) { 1.0 }

    assert_equal 9 * Codec::BYTES_PER_SAMPLE, tile.heights.bytesize
  end

  test "the base centres the tile's own range and the bounds report it" do
    tile = Builder.encode(frame: frame, tx: 0, tz: 0) { |x, _z| x / 5.0 } # 0..100m

    assert_equal 5_000, tile.base_cm
    assert_equal 0, tile.min_cm
    assert_equal 10_000, tile.max_cm
  end

  test "a tile at negative coordinates samples negative metres" do
    tile = Builder.encode(frame: frame, tx: -1, tz: -1) { |x, z| (x + z) / 10.0 }
    metres = Codec.unpack(tile.heights, tile.base_cm)

    assert_equal(-100.0, metres.first, "the north-west corner is (-500, -500)")
    assert_equal 0.0, metres.last, "the south-east corner is (0, 0)"
  end

  # Neighbouring tiles share their edge samples. If two encodings of the same function
  # disagreed along the seam a car would hit an invisible step there.
  test "neighbouring tiles agree along their shared edge" do
    fn = ->(x, z) { Math.sin(x / 80.0) * 3 + z / 100.0 }
    west = Builder.encode(frame: frame, tx: 0, tz: 0, &fn)
    east = Builder.encode(frame: frame, tx: 1, tz: 0, &fn)
    w = Codec.unpack(west.heights, west.base_cm)
    e = Codec.unpack(east.heights, east.base_cm)

    3.times { |row| assert_equal w[row * 3 + 2], e[row * 3], "row #{row}" }
  end

  test "reads back through the tile it encodes" do
    encoded = Builder.encode(frame: frame, tx: 0, tz: 0) { |x, z| x / 100.0 + z / 1000.0 }
    tile = Game::Terrain::Tile.new(
      tx: 0, tz: 0, n: frame.height_n, base_cm: encoded.base_cm, blob: encoded.heights, frame: frame
    )

    assert_in_delta 2.5, tile.at(0, 1), 1e-9
    assert_in_delta 5.5, tile.at(2, 2), 1e-9
  end
end
