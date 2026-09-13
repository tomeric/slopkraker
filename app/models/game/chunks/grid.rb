module Game
  module Chunks
    # The streaming grid: which chunk a point falls in, and which chunks a player needs
    # around them.
    #
    # Chunks nest inside terrain tiles rather than matching them. A tile is sized for
    # terrain, which is cheap per square metre and wants few large pieces; a chunk is sized
    # for buildings, which are expensive and want to arrive a few at a time. World's
    # chunk_size is validated to divide tile_size so the two can never disagree about who
    # owns a point.
    class Grid
      attr_reader :frame

      def initialize(frame:)
        @frame = frame
      end

      def of(gx, gz)
        frame.chunk_of(gx, gz)
      end

      def origin_of(cx, cz)
        [ cx * frame.chunk_size, cz * frame.chunk_size ]
      end

      def centre_of(cx, cz)
        half = frame.chunk_size / 2.0
        [ cx * frame.chunk_size + half, cz * frame.chunk_size + half ]
      end

      # Every chunk whose centre is within `radius` of the point, nearest first -- which is
      # the order a streamer wants to load them in.
      def within(gx, gz, radius)
        reach = (radius / frame.chunk_size).ceil
        cx, cz = of(gx, gz)

        ((cx - reach)..(cx + reach)).to_a.product(((cz - reach)..(cz + reach)).to_a)
          .map { |x, z| [ [ x, z ], distance_to(gx, gz, x, z) ] }
          .select { |_, distance| distance <= radius }
          .sort_by { |_, distance| distance }
          .map(&:first)
      end

      def distance_to(gx, gz, cx, cz)
        x, z = centre_of(cx, cz)
        Math.hypot(x - gx, z - gz)
      end
    end
  end
end
