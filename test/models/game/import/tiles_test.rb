require "test_helper"

class Game::Import::TilesTest < ActiveSupport::TestCase
  # A DEM that is exactly its own NAP height everywhere: 64 m, the estate's ground.
  #
  # 600 m square centred on tile (2, -5), which is 500 m: fifty metres of margin on every
  # side. The margin is not decoration. A tile's outermost samples sit ON its edge, and the
  # DEM interpolates between sample CENTRES, so a grid cut to the tile's own extent has no
  # four samples to blend at the rim and Dem refuses -- correctly, because a survey that
  # does not reach is not a survey to guess from.
  def tiles
    path = binary_fixture("dem_flat.raw", ([ 64.0 ] * (60 * 60)).pack("e*"))
    dem = Game::Import::Dem.new(path: path, origin_x: 185_950.0, origin_y: 332_550.0, step: 10.0, cols: 60, rows: 60)
    Game::Import::Tiles.new(dem: dem, frame: Game::Terrain::Frame.mijnstreek, origin_z: 60.0)
  end

  test "a tile is encoded from the DEM in game metres above origin_z" do
    tile = tiles.encode(2, -5)
    metres = Game::Terrain::HeightsCodec.unpack(tile.heights, tile.base_cm)

    assert_equal 51 * 51, metres.length
    assert_in_delta 4.0, metres[1300], 1e-6
    assert_in_delta 4.0, tiles.ground(1330.0, -2234.0), 1e-6
  end
end
