module Game
  module Building
    # Where the windows and the door go, and what sits above them.
    #
    # Openings are whole cells. A window is one cell of glass, a door one cell of timber,
    # and the cell directly above each is a steel lintel -- which is both what a real wall
    # has there and a cheap way of making the grid read as architecture rather than as a
    # grid. Sub-cell openings would mean clipping polygons identically in Ruby and in
    # JavaScript; the sibling map app needs six hundred lines of Sutherland-Hodgman for
    # exactly that, and this deliberately does not.
    #
    # The consequence to accept: a 1.5m cell means a 1.5m door. At this scale the whole
    # building is an approximation, and a door you can drive a buggy through is arguably
    # the point.
    #
    # Deterministic from the recipe's seed, so the same building generates identically
    # every time. It has to: a piece index means nothing if the wall it refers to might
    # have had its windows somewhere else.
    class Openings
      # The ground floor of the first edge gets the front door.
      DOOR_EDGE = 0
      DOOR_STOREY = 0

      def initialize(seed:)
        @seed = seed
      end

      def for_wall(edge:, storey:, cols:, rows:)
        patches = []
        window_columns(edge, storey, cols).each do |col|
          patches.concat(opening(col, rows, :glass))
        end

        if edge == DOOR_EDGE && storey == DOOR_STOREY
          door = cols / 2
          # The door displaces whatever window would have been there.
          patches.reject! { |patch| patch.col0 == door }
          patches.concat(opening(door, rows, :timber))
        end

        patches
      end

      private
        attr_reader :seed

        # The opening sits on the floor of its storey and the lintel goes directly above
        # it. With a 1.5m cell and a 3m storey that is two rows: opening, then lintel.
        def opening(col, rows, material)
          patches = [ Surface::Patch.new(col0: col, row0: 0, col1: col, row1: 0, material: material) ]
          return patches if rows < 2

          patches << Surface::Patch.new(col0: col, row0: 1, col1: col, row1: 1, material: :steel)
        end

        # Every other column, offset by the edge and storey so the faces are not identical
        # and the building does not read as wallpaper.
        def window_columns(edge, storey, cols)
          return [] if cols < 2

          start = 1 + ((seed + edge * 3 + storey) % 2)
          (start...cols).step(2).to_a
        end
    end
  end
end
