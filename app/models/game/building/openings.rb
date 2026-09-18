module Game
  module Building
    # Where the windows and the door go, by what the building IS.
    #
    # Openings are whole cells, so the grid decides what a window can be. Sub-cell openings
    # would mean clipping polygons identically in Ruby and in JavaScript; the sibling map
    # app needs six hundred lines of Sutherland-Hodgman for exactly that, and this
    # deliberately does not.
    #
    # Which means the cell size is an architectural decision. At 1m cells a 3m storey is
    # three rows, and that third row is what lets a window sit at eye level instead of on
    # the floor.
    #
    # Deterministic from the recipe's seed, so the same building generates identically
    # every time. It has to: a piece index means nothing if the wall it refers to might
    # have had its windows somewhere else.
    #
    # STYLES change PATCHES -- which cells are glass, door or lintel -- and never grids, so
    # no style changes a piece count or an offset. They live here rather than in the spec
    # because they change surfaces, and the row tests pin them.
    class Openings
      # The ground floor of the first edge gets the door.
      DOOR_EDGE = 0
      DOOR_STOREY = 0
      # A window wants a course beneath it. Where the storey is too short to give it one it
      # sits on the floor, which is at least honest about the grid it is drawn on.
      SILL_ROW = 1

      STYLES = {
        # The single free-standing `building` recipe, EXACTLY as it always was: a
        # three-cell timber door under a steel lintel, centred, windows every other column.
        # The four hand-made worlds are built from this and must not move.
        classic: { door: { cols: 3, rows: 2, material: :timber, lintel: true, at: :centre }, windows: :alternate, tall: 1, ground_sill: 0 },
        # A dwelling's front: a one-cell door near one end with a two-cell window beside
        # it, a pier between, and nothing else on the ground floor of the front. Three
        # metres of door is a garage, and driving through a house never needed the door --
        # you drive through the wall, and the wall is what the game is about.
        house: { door: { cols: 1, rows: 2, material: :door, lintel: false, at: :side }, windows: :alternate, tall: 1, front_window: 2 },
        # An annex, an outbuilding with windows, the end of a row: no door, every other column.
        annex: { door: nil, windows: :alternate, tall: 1 },
        # A garage: a door two rows tall across the face, a cell in from either side when
        # the face is five cells or more, the whole face when it is not.
        garage: { door: { cols: :wide, rows: 2, material: :door, lintel: false, at: :centre }, windows: :none, tall: 1 },
        # A church's parts. The nave gets a two-cell door and tall windows every third
        # column; a tower one small window per storey; a chapel a window every other column.
        nave: { door: { cols: 2, rows: 2, material: :door, lintel: false, at: :centre }, windows: :third, tall: 2 },
        tower: { door: nil, windows: :one, tall: 1 },
        chapel: { door: nil, windows: :alternate, tall: 1 }
      }.freeze

      attr_reader :style

      def initialize(seed:, style: :classic)
        @seed = seed
        @name = style.to_sym
        @style = STYLES.fetch(@name)
      end

      def for_wall(edge:, storey:, cols:, rows:)
        doorway = door(cols, rows) if door_face?(edge, storey, cols)
        front = doorway && style[:front_window] ? front_window(cols, rows, doorway.first) : nil
        windows =
          if front
            # The ground floor of a dwelling's front is the door and its window and nothing
            # else; a third opening on a six-metre face is a shop.
            Array(front)
          else
            window_columns(edge, storey, cols)
              .reject { |col| doorway && doorway.any? { |p| p.covers?(0, col) } }
              .map { |col| window(col, rows) }
          end
        windows + Array(doorway)
      end

      # The columns the door occupies on the door face, or none. A garden path has to meet
      # the door, so the hedge asks this of the same object the front wall was punctured by.
      def door_columns(cols)
        return [] unless door_face?(DOOR_EDGE, DOOR_STOREY, cols)

        first, last = door_span(cols)
        (first..last).to_a
      end

      # A face narrower than three cells gets no door: at one-metre cells a two-cell shed
      # front was all door under a full-width lintel.
      def door_face?(edge, storey, cols)
        !style[:door].nil? && edge == DOOR_EDGE && storey == DOOR_STOREY && cols >= 3
      end

      private
        attr_reader :seed

        def sill(rows)
          return style[:ground_sill] if rows < 3 && style.key?(:ground_sill)

          rows >= 3 ? SILL_ROW : [ rows - 1, 0 ].max
        end

        # One cell wide, `tall` rows when there is a course below and above them, one row
        # otherwise. A two-row window in a two-row storey is a hole, not a window.
        def window(col, rows)
          row = sill(rows)
          height = rows >= style[:tall] + 2 ? style[:tall] : 1
          Surface::Patch.new(col0: col, row0: row, col1: col, row1: row + height - 1, material: :glass)
        end

        # The two-cell window beside a dwelling's door, on the side away from the end the
        # door stands near, with one pier between. None if the face has no room for it.
        def front_window(cols, rows, door)
          left = door.col0 + 2
          right = door.col0 - 3
          col0 = door.col0 < cols / 2 ? left : right
          return nil unless col0 >= 0 && col0 + style[:front_window] - 1 <= cols - 1

          row = sill(rows)
          Surface::Patch.new(col0: col0, row0: row, col1: col0 + style[:front_window] - 1, row1: row, material: :glass)
        end

        def door(cols, rows)
          spec = style[:door]
          first, last = door_span(cols)
          height = [ spec[:rows], rows ].min
          patches = [ Surface::Patch.new(col0: first, row0: 0, col1: last, row1: height - 1, material: spec[:material]) ]
          return patches unless spec[:lintel] && rows > height

          # The one place steel reads as structure rather than as a dark square in the
          # middle of a wall: a lintel actually spanning something.
          patches << Surface::Patch.new(col0: first, row0: height, col1: last, row1: height, material: :steel)
        end

        # Where the door stands. Centred for a classic door, a portal and a garage; near one
        # end for a dwelling, which end decided by the seed so a terrace is not a row of
        # identical fronts. `wide` is the face minus a cell each side, or the whole face
        # under five cells.
        def door_span(cols)
          spec = style[:door]
          case spec[:cols]
          when :wide
            margin = cols >= 5 ? 1 : 0
            [ margin, cols - 1 - margin ]
          else
            width = [ spec[:cols], cols ].min
            first =
              if spec[:at] == :side
                seed.odd? ? cols - 1 - width : 1
              else
                [ (cols - width) / 2, 0 ].max
              end
            [ first, first + width - 1 ]
          end
        end

        # Every other column, offset by the edge and storey so the faces are not identical
        # and the building does not read as wallpaper; every third, the same way, for a
        # nave; the middle column alone for a tower.
        def window_columns(edge, storey, cols)
          case style[:windows]
          when :none then []
          when :one then cols >= 3 ? [ cols / 2 ] : []
          when :third
            return [] if cols < 3

            start = 1 + ((seed + edge) % 2)
            (start...(cols - 1)).step(3).to_a
          else
            return [] if cols < 2

            start = 1 + ((seed + edge * 3 + storey) % 2)
            (start...cols).step(2).to_a
          end
        end
    end
  end
end
