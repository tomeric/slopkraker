require "test_helper"

class Game::Terrain::SamplerTest < ActiveSupport::TestCase
  # A 3x3 sample tile at 250m spacing, so one tile is 500m across and the arithmetic is
  # easy to follow by hand.
  def tile(heights, tx: 0, tz: 0, frame: self.frame)
    base = Game::Terrain::HeightsCodec.base_for(heights)
    Game::Terrain::Tile.new(
      tx: tx, tz: tz, n: 3, base_cm: base, frame: frame,
      blob: Game::Terrain::HeightsCodec.pack(heights, base)
    )
  end

  def frame
    @frame ||= Game::Terrain::Frame.new(tile_size: 500, height_step: 250)
  end

  def flat_tile(height, **)
    tile(Array.new(9, height), **)
  end

  test "a sample lands exactly on its own height" do
    #   col ->      0     1     2
    heights = [ 0.0,  1.0,  2.0,   # row 0, northernmost
                3.0,  4.0,  5.0,   # row 1
                6.0,  7.0,  8.0 ]  # row 2
    sampler = Game::Terrain::Sampler.new(frame: frame, tiles: [ tile(heights) ])

    assert_in_delta 0.0, sampler.height_at(0.0, 0.0), 1e-6
    assert_in_delta 2.0, sampler.height_at(500.0 - 1e-9, 0.0), 1e-6
    assert_in_delta 8.0, sampler.height_at(500.0 - 1e-9, 500.0 - 1e-9), 1e-6
  end

  # Columns run with x and rows run with z, rows north to south. Transpose these by
  # accident and the terrain is mirrored about its own diagonal -- which looks like
  # perfectly good terrain until it is compared with the map it came from.
  test "columns run east and rows run south" do
    heights = [ 0.0, 0.0, 0.0,
                0.0, 0.0, 0.0,
                9.0, 9.0, 9.0 ]
    sampler = Game::Terrain::Sampler.new(frame: frame, tiles: [ tile(heights) ])

    assert_in_delta 9.0, sampler.height_at(0.0, 500.0 - 1e-9), 1e-6, "south edge should be high"
    assert_in_delta 0.0, sampler.height_at(500.0 - 1e-9, 0.0), 1e-6, "east edge should be flat"
  end

  test "a flat tile is flat everywhere inside it" do
    sampler = Game::Terrain::Sampler.new(frame: frame, tiles: [ flat_tile(12.5) ])

    [ [ 0.0, 0.0 ], [ 123.4, 456.7 ], [ 499.9, 1.0 ], [ 250.0, 250.0 ] ].each do |x, z|
      assert_in_delta 12.5, sampler.height_at(x, z), 1e-6
    end
  end

  # The whole point of the triangle convention. On a cell with one raised corner the two
  # triangles are different planes, and the midpoint of the shared edge is the only place
  # they agree -- so a bilinear average would differ from what is actually drawn
  # everywhere else.
  test "interpolation follows the triangle, not the bilinear average" do
    heights = [ 0.0, 0.0, 0.0,
                0.0, 0.0, 0.0,
                0.0, 0.0, 0.0 ]
    heights[3] = 0.0
    raised = heights.dup
    raised[0] = 4.0 # north-west corner of the first cell
    sampler = Game::Terrain::Sampler.new(frame: frame, tiles: [ tile(raised) ])

    # Inside the first triangle (fu + fv <= 1), the plane through (4, 0, 0) falls off
    # linearly in both directions.
    assert_in_delta 2.0, sampler.height_at(125.0, 0.0), 1e-6
    assert_in_delta 2.0, sampler.height_at(0.0, 125.0), 1e-6

    # Beyond the shared edge the second triangle is flat, because none of its three
    # corners is the raised one. A bilinear surface would still be above zero here.
    assert_in_delta 0.0, sampler.height_at(200.0, 200.0), 1e-6
  end

  test "the shared edge agrees from both triangles" do
    raised = Array.new(9, 0.0)
    raised[0] = 4.0
    sampler = Game::Terrain::Sampler.new(frame: frame, tiles: [ tile(raised) ])

    from_first = sampler.height_at(125.0 - 1e-6, 125.0 - 1e-6)
    from_second = sampler.height_at(125.0 + 1e-6, 125.0 + 1e-6)

    assert_in_delta from_first, from_second, 1e-4
  end

  # Neighbouring tiles share their edge samples, so the seam between them has to be flat.
  # If it is not, a car crossing a tile boundary hits a step that is invisible on screen.
  test "a shared edge between tiles has no step" do
    west = flat_tile(5.0, tx: 0)
    east = flat_tile(5.0, tx: 1)
    sampler = Game::Terrain::Sampler.new(frame: frame, tiles: [ west, east ])

    assert_in_delta 5.0, sampler.height_at(500.0 - 1e-6, 10.0), 1e-6
    assert_in_delta 5.0, sampler.height_at(500.0 + 1e-6, 10.0), 1e-6
  end

  test "a point past the seeded tiles falls back rather than raising" do
    sampler = Game::Terrain::Sampler.new(frame: frame, tiles: [ flat_tile(5.0) ], fallback: -1.0)

    assert_equal(-1.0, sampler.height_at(10_000.0, 10_000.0))
  end

  test "tiles at negative coordinates resolve" do
    sampler = Game::Terrain::Sampler.new(frame: frame, tiles: [ flat_tile(7.0, tx: -1, tz: -1) ])

    assert_in_delta 7.0, sampler.height_at(-250.0, -250.0), 1e-6
  end
end
