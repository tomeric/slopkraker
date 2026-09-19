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
        out = outward(recipe.footprint)
        recipe.edges.each_with_index.flat_map do |(from, to), edge|
          recipe.storeys.times.map do |storey|
            wall(recipe, from, to, edge: edge, storey: storey, openings: openings, outward: out)
          end
        end
      end

      def self.wall(recipe, from, to, edge:, storey:, openings:, outward: -1)
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
          seed: recipe.seed,
          outward: outward
        )
      end

      # At least one cell, and the actual cell size is the extent divided by however many
      # we settled on -- so the target size is advisory and the grid always fits its
      # surface exactly rather than accumulating a remainder along the way.
      def self.cells(extent, target)
        [ (extent / target).round, 1 ].max
      end

      # Which way a ring is wound, as the sign that turns a wall's own u x v normal (see
      # Surface#outward) into a vector pointing OUTWARD. Every wall here is built with u
      # running along the wall (from -> to) and v = UP, so its stored normal comes out to
      # u x v = (-u.z, 0, u.x) -- and the sign of that cross product is exactly the sign of
      # the ring's own shoelace sum below (Recipe#footprint_area takes this same sum's
      # magnitude, for the same reason: it does not care which way a ring winds).
      #
      # A ring laid out by hand always runs (x0,z0) -> (x1,z0) -> (x1,z1) -> (x0,z1), which
      # comes out positive, and for that winding u x v points INTO the ring -- hence -1. An
      # imported ring makes no such promise: PostGIS hands Import::Rows#ring whichever way
      # the source geometry wound, and 58 of geleen's 93 box rings run the other way, where
      # u x v already points out and this returns +1.
      def self.outward(ring)
        area = ring.each_with_index.sum { |(x1, z1), i| x2, z2 = ring[(i + 1) % ring.length]; x1 * z2 - x2 * z1 }
        area.positive? ? -1 : 1
      end
    end
  end
end
