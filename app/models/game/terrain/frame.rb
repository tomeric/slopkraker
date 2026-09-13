module Game
  module Terrain
    # The mapping between a survey coordinate system and game metres, and the two grids
    # laid over the result.
    #
    # Game axes are x east, z south, y up. A projected metric system measures x east and
    # y north, so the conversion is a subtraction and a sign flip -- no reprojection, no
    # trigonometry. That is the entire reason real survey data can be imported later
    # without a second code path: pick the origin, subtract, and the numbers are already
    # game coordinates.
    #
    # `origin_z` does the same job vertically. Elevation data is quoted against a national
    # datum and can be tens of metres above zero everywhere; subtracting the origin keeps
    # that offset out of the terrain encoding instead of spending its precision on a
    # constant.
    class Frame
      attr_reader :origin_x, :origin_y, :origin_z, :srid, :tile_size, :height_step, :chunk_size

      # The sibling map app's frame, exactly. Named rather than described so that
      # compatibility is a failing test rather than a comment that drifts.
      def self.mijnstreek
        new(
          origin_x: 185_000.0, origin_y: 330_000.0, origin_z: 0.0, srid: 28992,
          tile_size: 500, height_step: 10, chunk_size: 125
        )
      end

      def initialize(origin_x: 0.0, origin_y: 0.0, origin_z: 0.0, srid: nil,
                     tile_size: 500, height_step: 5, chunk_size: 125)
        @origin_x = origin_x.to_f
        @origin_y = origin_y.to_f
        @origin_z = origin_z.to_f
        @srid = srid
        @tile_size = tile_size
        @height_step = height_step
        @chunk_size = chunk_size
      end

      # Survey easting/northing to game x/z.
      def to_game(x, y)
        [ x - origin_x, -(y - origin_y) ]
      end

      # And back, for writing results out against the source data.
      def to_source(gx, gz)
        [ gx + origin_x, origin_y - gz ]
      end

      def height_to_game(height)
        height - origin_z
      end

      def height_to_source(gy)
        gy + origin_z
      end

      def tile_of(gx, gz)
        [ (gx / tile_size).floor, (gz / tile_size).floor ]
      end

      def chunk_of(gx, gz)
        [ (gx / chunk_size).floor, (gz / chunk_size).floor ]
      end

      # One more than the number of cells: neighbouring tiles share their edge samples,
      # and that shared row is what keeps the seam between them flat.
      def height_n
        tile_size / height_step + 1
      end

      def chunks_per_tile
        tile_size / chunk_size
      end

      def to_spec
        {
          srid: srid,
          origin: [ origin_x, origin_y, origin_z ],
          tile_size: tile_size,
          height_step: height_step,
          height_n: height_n,
          chunk_size: chunk_size
        }
      end
    end
  end
end
