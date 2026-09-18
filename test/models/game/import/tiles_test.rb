require "test_helper"

class Game::Import::TilesTest < ActiveSupport::TestCase
  N = 51                                                    # samples along a 500 m tile at 10 m
  DEM_X, DEM_Y, STEP, SIDE = 185_950.0, 332_550.0, 10.0, 60

  # A DEM that SLOPES, and by a different amount along each axis:
  #
  #   NAP(x, y) = 64 + (x - 185950) / 1000 - (332550 - y) / 500
  #
  # A metre east adds a millimetre, a metre south takes two away. A constant field was
  # worse than no test: every assertion about a height held for every point in range, so a
  # sign error in `to_source`, a transposed row and column, or the wrong `origin_z` all
  # passed, and Tiles exists for nothing but that round trip. The two gradients differ in
  # magnitude AND in sign on purpose -- with one gradient, or two alike, swapping the axes
  # is invisible.
  #
  # Linear in x and y, so bilinear interpolation over it is exact and the expected numbers
  # below are not approximations; the tolerances are float32 storage of the samples (~4e-6)
  # and, for a decoded tile, the codec's one-centimetre quantisation.
  #
  # 600 m square centred on tile (2, -5), which is 500 m: fifty metres of margin on every
  # side. The margin is not decoration. A tile's outermost samples sit ON its edge, and the
  # DEM interpolates between sample CENTRES, so a grid cut to the tile's own extent has no
  # four samples to blend at the rim and Dem refuses -- correctly, because a survey that
  # does not reach is not a survey to guess from.
  def nap(x, y) = 64.0 + (x - DEM_X) / 1000.0 - (DEM_Y - y) / 500.0

  def tiles
    @tiles ||= begin
      # Rows north to south, columns west to east, each sample at its own cell's centre --
      # the order Dem reads and the order the codec and the sibling map app agree on.
      samples = (0...SIDE).flat_map { |row| (0...SIDE).map { |col| nap(DEM_X + (col + 0.5) * STEP, DEM_Y - (row + 0.5) * STEP) } }
      path = binary_fixture("dem_slope.raw", samples.pack("e*"))
      dem = Game::Import::Dem.new(path: path, origin_x: DEM_X, origin_y: DEM_Y, step: STEP, cols: SIDE, rows: SIDE)
      Game::Import::Tiles.new(dem: dem, frame: Game::Terrain::Frame.mijnstreek, origin_z: 60.0)
    end
  end

  # Worked from the formula and nothing else. RD from game is x = gx + 185000 and
  # y = 330000 - gz, and a game height is NAP minus the world's origin_z of 60, so
  #
  #   ground(gx, gz) = 4 + (gx - 950) / 1000 - (2550 + gz) / 500
  #
  #   (1330, -2234) -> 4 + 0.380 - 0.632 = 3.748     the estate spawn
  #   (1430, -2234) -> 4 + 0.480 - 0.632 = 3.848     100 m east:  a tenth of a metre UP
  #   (1330, -2134) -> 4 + 0.380 - 0.832 = 3.548     100 m south: two tenths DOWN
  test "the ground slopes the way the survey does, along both axes and by the right amount" do
    assert_in_delta 3.748, tiles.ground(1330.0, -2234.0), 1e-4
    assert_in_delta 3.848, tiles.ground(1430.0, -2234.0), 1e-4
    assert_in_delta 3.548, tiles.ground(1330.0, -2134.0), 1e-4
  end

  test "a tile is encoded from the DEM in game metres above origin_z" do
    tile = tiles.encode(2, -5)
    metres = Game::Terrain::HeightsCodec.unpack(tile.heights, tile.base_cm)

    assert_equal N * N, metres.length

    # Checked OFF the diagonal, and this is the point of the index. TileBuilder walks
    # k.divmod(n) as (row, col) over gx = tx * 500 + col * 10, gz = tz * 500 + row * 10, so
    # a sample whose row and column are equal reads the same either way round and says
    # nothing about which is which. 388 is row 7, column 31 -- (1310, -2430), which the
    # formula puts at 4 + 0.360 - 0.240 = 4.12. Read transposed it would be (1070, -2190),
    # which is 3.40, so the two cannot be confused for one another.
    row, col = 388.divmod(N)
    assert_equal [ 7, 31 ], [ row, col ]
    assert_equal [ 1310, -2430 ], [ 2 * 500 + col * 10, -5 * 500 + row * 10 ]
    assert_in_delta 4.12, metres[388], 5e-3
  end
end
