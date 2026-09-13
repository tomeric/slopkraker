module Game
  module Building
    # Exterior walls: one surface per footprint edge per storey.
    #
    # Split by storey rather than run full height, because a storey is the unit a building
    # collapses by. Keeping the two aligned means the collapse rule can weigh what is left
    # of a storey without working out which part of a taller surface belonged to it.
    module Walls
      THICKNESS = 0.3
      UP = Vector3.new(0, 1, 0)

      def self.build(recipe, openings:)
        recipe.edges.each_with_index.flat_map do |(from, to), edge|
          recipe.storeys.times.map do |storey|
            wall(recipe, from, to, edge: edge, storey: storey, openings: openings)
          end
        end
      end

      def self.wall(recipe, from, to, edge:, storey:, openings:)
        along = Vector3.new(to[0] - from[0], 0.0, to[1] - from[1])
        length = along.length
        cols = cells(length, recipe.cell)
        rows = cells(recipe.storey_height, recipe.cell)

        Surface.new(
          kind: :wall,
          storey: storey,
          material: Materials.fetch(:brick),
          origin: Vector3.new(from[0], storey * recipe.storey_height, from[1]),
          u: along.normalised,
          v: UP,
          width: length,
          height: recipe.storey_height,
          cols: cols,
          rows: rows,
          thickness: THICKNESS,
          patches: openings.for_wall(edge: edge, storey: storey, cols: cols, rows: rows),
          seed: recipe.seed
        )
      end

      # At least one cell, and the actual cell size is the extent divided by however many
      # we settled on -- so the target size is advisory and the grid always fits its
      # surface exactly rather than accumulating a remainder along the way.
      def self.cells(extent, target)
        [ (extent / target).round, 1 ].max
      end
    end
  end
end
