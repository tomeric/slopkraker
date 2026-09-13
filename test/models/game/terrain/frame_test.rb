require "test_helper"

class Game::Terrain::FrameTest < ActiveSupport::TestCase
  test "a synthetic world's frame is the identity but for the axis flip" do
    frame = Game::Terrain::Frame.new

    assert_equal [ 10.0, -20.0 ], frame.to_game(10.0, 20.0)
    assert_equal [ 10.0, 20.0 ], frame.to_source(10.0, -20.0)
  end

  test "survey coordinates round trip" do
    frame = Game::Terrain::Frame.mijnstreek
    easting = 190_500.0
    northing = 335_250.0

    gx, gz = frame.to_game(easting, northing)

    assert_in_delta easting, frame.to_source(gx, gz)[0], 1e-9
    assert_in_delta northing, frame.to_source(gx, gz)[1], 1e-9
  end

  # North is -z, so a point further north than the origin must land at a negative z. Get
  # this backwards and the whole map is mirrored, which looks plausible until it is
  # compared with anything real.
  test "north of the origin is negative z" do
    frame = Game::Terrain::Frame.mijnstreek

    _, gz = frame.to_game(frame.origin_x, frame.origin_y + 100.0)

    assert_equal(-100.0, gz)
  end

  test "elevation is measured from the world origin" do
    frame = Game::Terrain::Frame.new(origin_z: 22.7)

    assert_in_delta 2.3, frame.height_to_game(25.0), 1e-9
    assert_in_delta 25.0, frame.height_to_source(2.3), 1e-9
  end

  # The sibling map app's numbers, asserted rather than described, so that a change here
  # that would break importing its data fails instead of drifting quietly.
  test "the mijnstreek frame matches the map app exactly" do
    frame = Game::Terrain::Frame.mijnstreek

    assert_equal 28_992, frame.srid
    assert_equal 185_000.0, frame.origin_x
    assert_equal 330_000.0, frame.origin_y
    assert_equal 500, frame.tile_size
    assert_equal 10, frame.height_step
    assert_equal 51, frame.height_n
  end

  test "tiles and chunks floor toward negative coordinates" do
    frame = Game::Terrain::Frame.new(tile_size: 500, chunk_size: 125)

    assert_equal [ 0, 0 ], frame.tile_of(0.0, 0.0)
    assert_equal [ 0, 0 ], frame.tile_of(499.9, 499.9)
    assert_equal [ 1, 1 ], frame.tile_of(500.0, 500.0)
    assert_equal [ -1, -1 ], frame.tile_of(-0.1, -0.1)
    assert_equal [ -1, -1 ], frame.tile_of(-500.0, -500.0)
    assert_equal [ -2, -2 ], frame.tile_of(-500.1, -500.1)
  end

  test "chunks nest inside tiles" do
    frame = Game::Terrain::Frame.new(tile_size: 500, chunk_size: 125)

    assert_equal 4, frame.chunks_per_tile
  end
end
