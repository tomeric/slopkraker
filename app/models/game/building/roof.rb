module Game
  module Building
    # The roof, and the gable ends that close it off.
    #
    # A gable is two pitched planes meeting at a ridge, plus a triangle at each end. The
    # triangles are generated as full rectangles and then clipped with `void` cells rather
    # than by cutting the grid down, because the grid is what piece indices are counted
    # from. Clipping the grid would mean Ruby and JavaScript both having to clip it
    # identically forever; clipping the contents means neither of them has to know.
    #
    # The wasted indices are the corners of two triangles -- a handful of bits in a bitset
    # that is twenty bytes to begin with.
    module Roof
      THICKNESS = 0.2
      GABLE_THICKNESS = 0.3
      # Real eaves hang past the wall, and here it does a second job: the gable behind is
      # a stair of whole cells, and an overhang is what hides the last step of it.
      OVERHANG = 0.4
      # How far the tiles reach DOWN the slope, past the wall. OVERHANG above is spent
      # along the ridge, past the gables; this is the other direction, and they are not
      # the same number just because they are the same size today.
      #
      # A wall straddles its own plane and a roof plane STARTS on it, so without this the
      # outer half of every wall top -- Walls::THICKNESS / 2, 150 mm -- is open sky, and
      # the gutter that hangs at the eaves hangs over that gap rather than clear of the
      # wall. It has to beat half a wall HORIZONTALLY, and it runs down the slope, so what
      # covers the wall is EAVES_OVERHANG * cos(pitch) -- about 350 mm on the pitches the
      # worlds have, which is why 0.4 rather than 0.2.
      #
      # DRAWING, like the gable caps, and never a longer plane: more rows is more cells,
      # and more cells is every piece index after it.
      EAVES_OVERHANG = 0.4
      EAST = Vector3.new(1, 0, 0)
      SOUTH = Vector3.new(0, 0, 1)
      UP = Vector3.new(0, 1, 0)

      def self.build(recipe)
        case recipe.roof
        when "flat" then [ flat(recipe) ]
        else gable(recipe)
        end
      end

      def self.flat(recipe)
        [ Surface.new(
          kind: :roof, storey: recipe.storeys,
          material: Materials.fetch(:concrete),
          origin: Vector3.new(recipe.min_x, recipe.eaves, recipe.min_z),
          u: EAST, v: SOUTH,
          width: recipe.width, height: recipe.depth,
          cols: Walls.cells(recipe.width, recipe.cell),
          rows: Walls.cells(recipe.depth, recipe.cell),
          thickness: THICKNESS
        ) ].first
      end

      def self.gable(recipe)
        planes(recipe) + ends(recipe)
      end

      # Two slopes rising from opposite eaves to the ridge. `span` is the horizontal
      # distance each covers -- half the short axis -- and the slope itself is the
      # hypotenuse of that and the rise.
      def self.planes(recipe)
        along_z = recipe.ridge_along_z?
        run = (along_z ? recipe.width : recipe.depth) / 2.0
        ridge_length = along_z ? recipe.depth : recipe.width
        slope = Math.hypot(run, recipe.rise)

        [ 1, -1 ].map do |side|
          origin = if along_z
            Vector3.new(side.positive? ? recipe.min_x : recipe.max_x, recipe.eaves, recipe.min_z)
          else
            Vector3.new(recipe.min_x, recipe.eaves, side.positive? ? recipe.min_z : recipe.max_z)
          end
          up_slope = if along_z
            Vector3.new(side * run, recipe.rise, 0.0)
          else
            Vector3.new(0.0, recipe.rise, side * run)
          end

          # Started half an overhang back along its own run and made that much longer at
          # each end, so the roof projects past both gables.
          span = ridge_length + OVERHANG * 2
          eave = (along_z ? SOUTH : EAST) * OVERHANG

          Surface.new(
            kind: :roof, storey: recipe.storeys,
            material: Materials.fetch(:roof_tile),
            origin: origin - eave,
            u: along_z ? SOUTH : EAST,
            v: up_slope.normalised,
            width: span, height: slope,
            cols: Walls.cells(span, recipe.cell),
            rows: Walls.cells(slope, recipe.cell),
            thickness: THICKNESS
          )
        end
      end

      # The triangles closing each end of the ridge.
      def self.ends(recipe)
        along_z = recipe.ridge_along_z?
        span = along_z ? recipe.width : recipe.depth
        cols = Walls.cells(span, recipe.cell)
        rows = [ Walls.cells(recipe.rise, recipe.cell), 1 ].max

        [ true, false ].map do |near|
          origin = if along_z
            Vector3.new(recipe.min_x, recipe.eaves, near ? recipe.min_z : recipe.max_z)
          else
            Vector3.new(near ? recipe.min_x : recipe.max_x, recipe.eaves, recipe.min_z)
          end

          Surface.new(
            kind: :gable, storey: recipe.storeys,
            material: Materials.fetch(:brick),
            origin: origin,
            u: along_z ? EAST : SOUTH,
            v: UP,
            width: span, height: recipe.rise,
            cols: cols, rows: rows,
            thickness: GABLE_THICKNESS,
            patches: clip(cols, rows),
            seed: recipe.seed
          )
        end
      end

      # Everything above the pitch line becomes void.
      #
      # Judged against the cell's TOP edge and against the LOWEST roof line over the whole
      # column -- the lower of the line's two ends, never its middle. A cell is a rectangle
      # spanning the column and the roof over it is a slope, so the line at the middle says
      # nothing about what the cell does at its outer edge: judged there, 166 of the 746
      # gable cells in the seeded worlds stood proud of their own roof, the worst by 1.92 m
      # through tiles 0.2 m thick -- brick teeth stepping up the verge, plain from the kerb.
      # Judged on the lower end, a kept cell is wholly beneath the roof everywhere across
      # its width, and what that leaves is a STEP rather than a tooth: the client fills it
      # with a box and a wedge (`game/world/gables.js`), which is drawing and costs no index.
      #
      # In integers, because the comparison is exact in them and a cell landing precisely on
      # the line is a cell to keep -- float rounding should not be what decides whether a
      # cell is a piece or a picture. The line at `k/cols` is `1 - |2k - cols| / cols` of the
      # height and a cell's top edge is `(row + 1) / rows` of it, so the whole test clears
      # its denominators.
      #
      # A GABLE IS NEVER CLIPPED TO NOTHING, and the fallbacks are ranked by how big a lie
      # each one tells. A cap hangs on a STANDING cell -- that is how it is hidden and
      # restored with the wall it fills -- so a gable with nothing standing is not a clean
      # triangle of caps, it is a hole where a wall was.
      #
      # Two shapes empty under the strict rule: one ONE ROW tall, whose only row reaches the
      # ridge and so is wholly under nothing; and one TWO COLUMNS wide, where the roof line
      # is zero at the outer edge of both. Such a gable keeps what the MIDDLE rule kept,
      # standing a little proud -- which is the very fault this method exists to fix, and is
      # still a far smaller lie than a missing gable.
      #
      # A gable that is BOTH at once -- two columns and one row -- empties under the middle
      # rule too, and that is two of Sint-Marcellinus's ends. They keep their bottom course
      # under the ridge: a rectangle where a very shallow triangle belongs, proud by at most
      # the rise, which on these is under one cell. What was there before anyone looked was
      # a 4.76 m hole in the side of a church.
      def self.clip(cols, rows)
        strict = void_cells(cols, rows) { |col| [ col, col + 1 ].map { |k| cols - (2 * k - cols).abs }.min }
        return strict unless strict.length == cols * rows

        middle = void_cells(cols, rows) { |col| midline(cols, col) }
        return middle unless middle.length == cols * rows

        ridge = (0...cols).max_by { |col| midline(cols, col) }
        under = (0...cols).select { |col| midline(cols, col) == midline(cols, ridge) }
        cols.times.flat_map do |col|
          rows.times.filter_map do |row|
            next if row.zero? && under.include?(col)

            Surface::Patch.new(col0: col, row0: row, col1: col, row1: row, material: :void)
          end
        end
      end

      # The roof line at a column's MIDDLE, as a numerator over `cols`. The rule every gable
      # was clipped by until 2026-09-19, kept because the degenerate shapes above still fall
      # back to it.
      def self.midline(cols, col)
        cols - (2 * col + 1 - cols).abs
      end

      # The cells above a per-column line, as void patches. `line` is in the same units the
      # callers use: numerator over `cols`, so the comparison stays in integers and a cell
      # landing exactly on the line is KEPT rather than lost to a float.
      def self.void_cells(cols, rows)
        cols.times.flat_map do |col|
          line = yield(col)

          rows.times.filter_map do |row|
            next if (row + 1) * cols <= rows * line

            Surface::Patch.new(col0: col, row0: row, col1: col, row1: row, material: :void)
          end
        end
      end

      # The same triangle, judged on the column's MIDDLE, for a surface that is the roof
      # rather than a wall under one.
      #
      # A gable end can afford the strict clip because the step it leaves is filled in by
      # the client's caps, and a cap hangs on the cell below it. A pyramid's four planes
      # (`RowGenerator.pyramid`) have no caps -- `gableCaps` is only run over `kind: gable`
      # -- so the strict clip there takes the apex cell of all four planes and leaves the
      # point open to the sky, which is the square hole the odd column count in
      # `RowGenerator.pyramid` exists to avoid. Judged on the middle, the apex column is
      # kept whole and the four planes still meet.
      #
      # This is a HOLDING position and not a claim that a roof plane is different in kind:
      # measured over the seeded worlds, 14 of the 34 cells these planes stand up are proud
      # of their own hip by up to 1.708 m, which is the same defect the gables had, at the
      # church tower's spire. Fixing it means capping a roof plane the way a gable is
      # capped, which needs the generator to say which planes carry the tent -- the client
      # can no more infer that than it can infer `Surface#fittings`.
      def self.clip_plane(cols, rows)
        cols.times.flat_map do |col|
          across = (col + 0.5) / cols
          line = 1.0 - (2.0 * across - 1.0).abs

          rows.times.filter_map do |row|
            next if line >= (row + 1).to_f / rows

            Surface::Patch.new(col0: col, row0: row, col1: col, row1: row, material: :void)
          end
        end
      end
    end
  end
end
