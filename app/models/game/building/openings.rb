module Game
  module Building
    # Where the windows and the door go.
    #
    # Openings are whole cells, so the grid decides what a window can be. Sub-cell openings
    # would mean clipping polygons identically in Ruby and in JavaScript; the sibling map
    # app needs six hundred lines of Sutherland-Hodgman for exactly that, and this
    # deliberately does not.
    #
    # Which means the cell size is an architectural decision. At 1m cells a 3m storey is
    # three rows, and that third row is what lets a window sit at eye level instead of on
    # the floor. It was on the floor while cells were 1.5m and a storey was two rows --
    # correct for that grid, and immediately wrong for this one.
    #
    # Deterministic from the recipe's seed, so the same building generates identically
    # every time. It has to: a piece index means nothing if the wall it refers to might
    # have had its windows somewhere else.
    class Openings
      # The ground floor of the first edge gets the front door.
      DOOR_EDGE = 0
      DOOR_STOREY = 0
      # Wide and tall enough to drive through, which is the whole point of a hollow
      # building.
      DOOR_WIDTH = 3
      DOOR_HEIGHT = 2

      # A window wants a course beneath it. Where the storey is too short to give it one it
      # sits on the floor, which is at least honest about the grid it is drawn on.
      SILL_ROW = 1

      def initialize(seed:)
        @seed = seed
      end

      def for_wall(edge:, storey:, cols:, rows:)
        doorway = door(cols, rows) if edge == DOOR_EDGE && storey == DOOR_STOREY

        windows = window_columns(edge, storey, cols)
          .reject { |col| doorway && doorway.first.covers?(0, col) }
          .map { |col| window(col, rows) }

        windows + Array(doorway)
      end

      private
        attr_reader :seed

        def window(col, rows)
          row = rows >= 3 ? SILL_ROW : 0
          Surface::Patch.new(col0: col, row0: row, col1: col, row1: row, material: :glass)
        end

        # The one place steel reads as structure rather than as a dark square in the middle
        # of a wall: a lintel actually spanning something. Above a single 1m window it was
        # just a hole's worth of shadow.
        def door(cols, rows)
          width = [ DOOR_WIDTH, cols ].min
          height = [ DOOR_HEIGHT, rows ].min
          first = [ (cols - width) / 2, 0 ].max
          last = first + width - 1

          patches = [
            Surface::Patch.new(col0: first, row0: 0, col1: last, row1: height - 1, material: :timber)
          ]
          return patches unless rows > height

          patches << Surface::Patch.new(
            col0: first, row0: height, col1: last, row1: height, material: :steel
          )
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
