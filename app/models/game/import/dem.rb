module Game
  module Import
    # A raw Float32 height grid -- the AHN terrain model resampled to ten metres, rows north
    # to south, columns west to east -- read a sample at a time. Knows the file's origin
    # and spacing and nothing else about where it came from.
    class Dem
      class NoData < StandardError; end
      BYTES = 4

      attr_reader :path, :origin_x, :origin_y, :step, :cols, :rows, :nodata

      def initialize(path:, origin_x:, origin_y:, step:, cols:, rows:, nodata: -9999.0)
        @path, @origin_x, @origin_y, @step, @cols, @rows, @nodata = path.to_s, origin_x, origin_y, step, cols, rows, nodata
        @file = File.open(@path, "rb")
      end

      # Bilinear over the four samples around (x, y). Our grid points fall on this grid's
      # pixel edges, so a straight read would pick a corner at random; the blend is smooth.
      def height_at(x, y)
        fx = (x - origin_x) / step - 0.5
        fy = (origin_y - y) / step - 0.5
        col = fx.floor
        row = fy.floor
        raise NoData, "(#{x}, #{y}) is outside the grid" if col < 0 || row < 0 || col + 1 >= cols || row + 1 >= rows

        tx = fx - col
        ty = fy - row
        h00 = sample(row, col)
        h01 = sample(row, col + 1)
        h10 = sample(row + 1, col)
        h11 = sample(row + 1, col + 1)
        (h00 * (1 - tx) + h01 * tx) * (1 - ty) + (h10 * (1 - tx) + h11 * tx) * ty
      end

      private
        def sample(row, col)
          @file.seek((row * cols + col) * BYTES)
          value = @file.read(BYTES).unpack1("e")
          raise NoData, "no data at row #{row}, col #{col}" if value.nil? || value <= nodata + 1 || value.nan?

          value
        end
    end
  end
end
