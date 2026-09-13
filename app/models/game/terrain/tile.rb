module Game
  module Terrain
    # One square of heightfield, decoded.
    #
    # Samples are stored rows north to south, columns west to east, which in game axes
    # means the column index runs with x and the row index runs with z. Row zero is the
    # tile's northern edge.
    class Tile
      # Each cell of the grid is drawn as two triangles, and which diagonal they share is
      # not a detail: sample it on the wrong side of the split and the surface the wheels
      # rest on is not the surface on screen. The error is largest exactly where terrain
      # is most interesting -- a step across a cell -- and it is silent, because physics
      # and rendering each look self-consistent.
      #
      # This is the anti-diagonal: the shared edge runs from the cell's north-east corner
      # to its south-west one, so a point is in the first triangle when fu + fv <= 1. It
      # matches both the sibling map app and Three.js's own plane geometry.
      #
      # Rapier's heightfield has its own convention and may not agree. A probe test
      # compares this against a downward raycast at hundreds of points either side of each
      # diagonal; if it disagrees, this method is the one place to flip.
      def self.interpolate(h00, h10, h01, h11, fu, fv)
        if fu + fv <= 1
          h00 + (h10 - h00) * fu + (h01 - h00) * fv
        else
          h11 + (h01 - h11) * (1 - fu) + (h10 - h11) * (1 - fv)
        end
      end

      attr_reader :tx, :tz, :n, :base_cm, :frame

      def initialize(tx:, tz:, n:, base_cm:, blob:, frame:)
        @tx = tx
        @tz = tz
        @n = n
        @base_cm = base_cm
        @frame = frame
        @samples = blob.unpack(HeightsCodec::FORMAT)
      end

      def origin_x = tx * frame.tile_size
      def origin_z = tz * frame.tile_size

      # Metres above the world origin at one sample.
      def at(row, col)
        (@samples[row * n + col] + base_cm) / 100.0
      end

      def contains?(gx, gz)
        frame.tile_of(gx, gz) == [ tx, tz ]
      end

      def height_at(gx, gz)
        step = frame.height_step
        u = (gx - origin_x).to_f / step
        v = (gz - origin_z).to_f / step

        col = u.floor.clamp(0, n - 2)
        row = v.floor.clamp(0, n - 2)

        self.class.interpolate(
          at(row, col), at(row, col + 1), at(row + 1, col), at(row + 1, col + 1),
          u - col, v - row
        )
      end

      def min_m = (@samples.min + base_cm) / 100.0
      def max_m = (@samples.max + base_cm) / 100.0
    end
  end
end
