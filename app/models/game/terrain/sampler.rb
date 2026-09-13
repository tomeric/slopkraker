module Game
  module Terrain
    # "What is the ground height here?" across a whole world's worth of tiles.
    #
    # Tiles share their edge samples, so a point exactly on a boundary resolves to the same
    # height from either side and the seam stays flat. Outside the seeded tiles the answer
    # is the fallback rather than an exception: a world can legitimately be asked about a
    # point past its edge -- a blast radius overhanging the boundary, a camera looking out
    # -- and the hard walls are what actually stop anything going there.
    class Sampler
      attr_reader :frame, :fallback

      def initialize(frame:, tiles: [], fallback: 0.0)
        @frame = frame
        @fallback = fallback
        @tiles = {}
        Array(tiles).each { |tile| add(tile) }
      end

      def add(tile)
        @tiles[[ tile.tx, tile.tz ]] = tile
        self
      end

      def tile_at(gx, gz)
        @tiles[frame.tile_of(gx, gz)]
      end

      def height_at(gx, gz)
        tile_at(gx, gz)&.height_at(gx, gz) || fallback
      end

      def size = @tiles.size
    end
  end
end
