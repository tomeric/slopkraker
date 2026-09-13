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
      # Judged against the cell's TOP edge, not its centre. A cell kept because its middle
      # was under the roof still stands half a cell proud of it, and a row of those reads
      # as teeth along the ridge -- which is exactly what it looked like. Testing the top
      # means a kept cell is always wholly beneath the roof; the small step it leaves under
      # the slope is what the eaves overhang is there to cover.
      def self.clip(cols, rows)
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
