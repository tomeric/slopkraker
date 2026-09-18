module Game
  module Import
    # Heightfield tiles from a survey grid, in the world's frame and above its origin_z.
    #
    # The whole of the difference between a synthetic world and an imported one: TileBuilder
    # asks for a height at a game point, and this answers by converting back to survey
    # coordinates and reading the DEM. Everything downstream -- the codec, the tile rows,
    # the collider, the mesh, the sampler -- is the same code hills runs on.
    class Tiles
      def initialize(dem:, frame:, origin_z:)
        @dem, @frame, @origin_z = dem, frame, origin_z
      end

      # Game metres above the world's origin_z. Outside the DEM this raises rather than
      # guessing -- a tile of invented ground is worse than no tile.
      def ground(gx, gz)
        x, y = @frame.to_source(gx, gz)
        @dem.height_at(x, y) - @origin_z
      end

      def encode(tx, tz) = Terrain::TileBuilder.encode(frame: @frame, tx: tx, tz: tz) { |gx, gz| ground(gx, gz) }
    end
  end
end
