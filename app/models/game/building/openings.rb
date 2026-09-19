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
      # A garage door: three cells wide, two rows tall, one pier from the front door, on
      # the side of the front away from it. Two cells when the face has no room for three;
      # none under that, and none on a face under six columns, where the door, a pier and
      # a garage would leave no wall at all.
      GARAGE_WIDTH = 3
      GARAGE_ROWS = 2
      GARAGE_MIN_COLS = 6
      # Glass from floor to ceiling at the back: three cells on a face of five or more
      # columns, two below that, one pier kept at each end.
      GLAZING_WIDTH = 3
      GLAZING_NARROW = 2
      # Two cells of glass and a pier at each end need four columns; below that the pier
      # at the far end has nowhere left to stand.
      GLAZING_MIN_COLS = 4
      BACK_EDGE = 2

      STYLES = {
        # The single free-standing `building` recipe, EXACTLY as it always was: a
        # three-cell timber door under a steel lintel, centred, windows every other column.
        # The four hand-made worlds are built from this and must not move.
        classic: { door: { cols: 3, rows: 2, material: :timber, lintel: true, at: :centre }, windows: :alternate, tall: 1, ground_sill: 0 },
        # A dwelling's front: a one-cell door near one end with a two-cell window beside
        # it, a pier between, and nothing else on the ground floor of the front -- or, for
        # a dwelling with a garage, the door, a pier and a garage door three cells wide.
        # Everywhere else the windows come in RUNS of one or two cells, because a wall of
        # identical one-cell windows every other column reads as wallpaper.
        house: { door: { cols: 1, rows: 2, material: :door, lintel: false, at: :side }, windows: :runs, tall: 1, front_window: 2 },
        # An annex, an outbuilding with windows, the end of a row: no door, runs.
        annex: { door: nil, windows: :runs, tall: 1 },
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

      # `garage` and `glazing` are one dwelling's flags, written by the importer, and only a
      # dwelling's own style reads them: the garage rides on that style's one-cell side door
      # and the glazing is gated on `front_window`, which `house` alone carries. A shed or a
      # nave handed either flag is built exactly as if it had not been.
      def initialize(seed:, style: :classic, garage: false, glazing: false)
        @seed = seed
        @name = style.to_sym
        @style = STYLES.fetch(@name)
        @garage = garage
        @glazing = glazing
      end

      # `reserved` is the columns another wall lands in. Two walls meeting at a corner each
      # straddle their own plane, so the perpendicular one eats half a thickness -- 150 mm --
      # into the end cell; an interior partition does the same in the middle of the wall it
      # meets. Glass in one of those columns is a pane with a wall a hand's breadth behind
      # it. Measured over the five worlds before this: 102 panes stood in a corner column,
      # and 70 walls had a partition through a window -- 44 of the 60 row ends a partition
      # reaches ALONG the row, and 26 of the 50 dwelling fronts and backs one reaches
      # ACROSS it. The CALLER works the list out, because the caller is the only thing that
      # knows the building: Walls and RowGenerator both know where their corners are, and
      # only RowGenerator knows which way a dwelling's partition runs.
      #
      # A DOOR is never reserved away. A door in a corner is a detail; a door that vanishes
      # is a house you cannot enter -- and the garage door is a door here for one more
      # reason: Gardens asks this same object for `garage_columns` so the drive through the
      # hedge lines up with it, and a door moved here but not there is a drive to a wall.
      def for_wall(edge:, storey:, cols:, rows:, reserved: [])
        reserved = reserved.select { |col| col.between?(0, cols - 1) }
        doorway = door(cols, rows) if door_face?(edge, storey, cols)
        garage = garage_door(cols, rows, doorway.first) if doorway && @garage
        return Array(doorway) + [ garage ] if garage

        glazing = glazing(cols, rows, reserved) if @glazing && style[:front_window] && edge == BACK_EDGE && storey == DOOR_STOREY && cols >= GLAZING_MIN_COLS
        return [ glazing ] if glazing

        front = doorway && style[:front_window] ? front_window(cols, rows, doorway.first, reserved) : nil
        windows =
          if front
            # The ground floor of a dwelling's front is the door and its window and nothing
            # else; a third opening on a six-metre face is a shop.
            Array(front)
          else
            window_runs(edge, storey, cols)
              # Shortened where a run can give up a cell and still be a window, dropped
              # where it cannot. A face whose every window lands on a wall gets none, which
              # is a blank wall rather than a pane looking into plaster.
              .filter_map { |col0, col1| clear_run(col0, col1, reserved) }
              .reject { |col0, col1| doorway && doorway.any? { |p| (col0..col1).any? { |col| p.covers?(0, col) } } }
              .map { |col0, col1| window_patch(col0, col1, rows) }
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

      # The columns the garage door occupies, or none. A garaged front needs a DRIVE as well
      # as a path, and the hedge is what would otherwise be grown across it -- so the garden
      # asks the same object the front wall was punctured by, exactly as it does for the door.
      def garage_columns(cols)
        return [] unless @garage && door_face?(DOOR_EDGE, DOOR_STOREY, cols)

        span = garage_span(cols, *door_span(cols))
        span ? (span.first..span.last).to_a : []
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

        # One patch over `col0..col1`, `tall` rows when there is a course below and above
        # them, one row otherwise. A two-row window in a two-row storey is a hole.
        def window_patch(col0, col1, rows)
          row = sill(rows)
          height = rows >= style[:tall] + 2 ? style[:tall] : 1
          Surface::Patch.new(col0: col0, row0: row, col1: col1, row1: row + height - 1, material: :glass)
        end

        # The longest stretch of `col0..col1` that no other wall lands in, or nil when every
        # column of it does. Leftmost on a tie, so a run that gives up a cell gives up the
        # one the wall is in and keeps the rest.
        def clear_run(col0, col1, reserved)
          best = nil
          run = nil
          (col0..col1).each do |col|
            if reserved.include?(col)
              run = nil
              next
            end

            run = run ? [ run.first, col ] : [ col, col ]
            best = run if best.nil? || run.last - run.first > best.last - best.first
          end
          best
        end

        # The two-cell window beside a dwelling's door, on the side away from the end the
        # door stands near, with one pier between. None if the face has no room for it.
        #
        # Where a wall lands on it, the far side of the door is tried and then both sides
        # are allowed to give up a cell -- widest wins, near side on a tie. There are only
        # ever two places this window can be, and on a five-column front with the door three
        # columns along, one cell at column 1 is the whole of what is left: a front with a
        # narrow window still reads as a front, and dropping it falls through to runs that
        # the door has already eaten, which is a blank wall with a door in it.
        def front_window(cols, rows, door, reserved = [])
          width = style[:front_window]
          near = door.col0 < cols / 2 ? door.col0 + 2 : door.col0 - 3
          far = door.col0 < cols / 2 ? door.col0 - 3 : door.col0 + 2
          span = nil
          [ near, far ].each do |candidate|
            next unless candidate >= 0 && candidate + width - 1 <= cols - 1

            run = clear_run(candidate, candidate + width - 1, reserved)
            span = run if run && (span.nil? || run.last - run.first > span.last - span.first)
          end
          return nil unless span

          row = sill(rows)
          Surface::Patch.new(col0: span.first, row0: row, col1: span.last, row1: row, material: :glass)
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

        # The garage door, on the side of the front away from the front door. At
        # GARAGE_MIN_COLS columns or more, the three cells always fit before the last
        # column given where the house door sits -- swept cols 6..30 across 50 seeds, the
        # shrink to two cells and the nil below never fired. They guard a future door
        # width or margin, not a case that happens today.
        def garage_door(cols, rows, door)
          span = garage_span(cols, door.col0, door.col1)
          return nil unless span

          Surface::Patch.new(col0: span.first, row0: 0, col1: span.last, row1: [ GARAGE_ROWS, rows ].min - 1, material: :door)
        end

        # Which columns it stands in, apart from the patch it becomes -- the drive through
        # the hedge is the same columns and must never be worked out a second way.
        def garage_span(cols, door_col0, door_col1)
          return nil if cols < GARAGE_MIN_COLS

          if door_col0 < cols / 2
            first = door_col1 + 2
            last = [ first + GARAGE_WIDTH - 1, cols - 1 ].min
          else
            last = door_col0 - 2
            first = [ last - GARAGE_WIDTH + 1, 0 ].max
          end
          return nil if last - first + 1 < 2

          [ first, last ]
        end

        # One glass patch from floor to ceiling, its start drawn from the seed so a terrace
        # of glazed backs is not a row of identical ones, a pier kept at each end.
        #
        # A partition landing in the middle of the back is the one thing that can stand in
        # its way -- the piers already keep it out of both corners -- so it slides along the
        # face from the seeded start until it clears, and a face where nothing clears gets
        # no glazing at all rather than a shopfront with a wall down the middle of it.
        def glazing(cols, rows, reserved = [])
          width = cols >= 5 ? GLAZING_WIDTH : GLAZING_NARROW
          room = cols - 2 - width
          start = room.positive? ? draw(BACK_EDGE, 0, 0) % (room + 1) : 0
          offset = (0..[ room, 0 ].max).find do |slide|
            first = 1 + (start + slide) % ([ room, 0 ].max + 1)
            (first..first + width - 1).none? { |col| reserved.include?(col) }
          end
          return nil unless offset

          first = 1 + (start + offset) % ([ room, 0 ].max + 1)
          Surface::Patch.new(col0: first, row0: 0, col1: first + width - 1, row1: rows - 1, material: :glass)
        end

        # Windows as runs: from a seeded start, each one or two cells wide by the seed,
        # one pier between, never reaching the last column. `[[col0, col1], …]`.
        def window_runs(edge, storey, cols)
          case style[:windows]
          when :runs
            return [] if cols < 3

            runs = []
            col = 1 + ((seed + edge * 3 + storey) % 2)
            k = 0
            while col <= cols - 2
              width = draw(edge, storey, k).even? ? 2 : 1
              width = 1 if col + width - 1 > cols - 2
              runs << [ col, col + width - 1 ]
              col += width + 1
              k += 1
            end
            runs
          else
            window_columns(edge, storey, cols).map { |col| [ col, col ] }
          end
        end

        # A small integer hash of the seed and a few salts, for the per-run and per-face
        # draws. Deterministic, like everything about a recipe has to be.
        #
        # THE FOLDING IS THE POINT. A bare `sum % 1_000_003` is not a hash: within one face
        # the quotient never rolls over, so consecutive `c` differ by exactly 7919 and the
        # low bit -- all `.even?` reads -- flips on every run. Measured that way, 79% of
        # faces with three runs or more went 2, 1, 2, 1 and 90% of dwellings wore the same
        # layout front and back, because the `a` salt is small too. Multiplying and folding
        # the high bits down twice avalanches both, which is what the runs were for.
        def draw(a, b, c)
          h = (seed * 2_654_435_761 + a * 40_503 + b * 9973 + c * 7919) & 0xffff_ffff
          h = (h * 2_246_822_519) & 0xffff_ffff
          h ^= h >> 16
          h = (h * 3_266_489_917) & 0xffff_ffff
          h ^= h >> 13
          h % 1_000_003
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
