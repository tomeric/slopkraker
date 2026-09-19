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
        # Every storey of a free-standing building has a partition across it, so the walls
        # it lands on are a fact about the recipe rather than something a caller supplies --
        # the same standing as the corner rule below, and it is asked here for the same
        # reason: there is nowhere a caller could opt out of it that would be right.
        reach = Interior.partition_reach(recipe)
        recipe.edges.each_with_index.flat_map do |(from, to), edge|
          recipe.storeys.times.map do |storey|
            wall(recipe, from, to, edge: edge, storey: storey, openings: openings, outward: out, reach: reach[edge])
          end
        end
      end

      def self.wall(recipe, from, to, edge:, storey:, openings:, outward: -1, reach: nil)
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
          # The first and last column of every wall of every recipe: a footprint is a closed
          # ring, so both ends of every edge meet another edge, and two walls at a corner
          # each straddle their own plane -- the perpendicular one eats half of THICKNESS
          # into the end cell whatever the building is. No caller can opt out of this one.
          # And the columns the interior partition lands in, which is the same fault in the
          # middle of a wall instead of at its end. Measured over the three hand-made worlds
          # before this: of the 76 walls a partition reaches, 38 had glass in the column its
          # centre line falls in and 46 in a column its thickness reaches.
          patches: openings.for_wall(edge: edge, storey: storey, cols: cols, rows: rows, reserved: [ 0, cols - 1 ] | columns(reach, cols)),
          seed: recipe.seed,
          outward: outward
        )
      end

      # The columns a stretch of this wall covers, from the fraction range
      # `Interior.partition_reach` gives it. Turned into columns HERE rather than there
      # because a column is this grid's unit: `cols` is rounded off the wall's own length,
      # and a second module rounding a second length is how two answers to one question
      # start disagreeing by a cell. A crossing within half a cell of either end comes back
      # as column 0 or cols - 1, which the corner rule has already reserved -- the union
      # above is what makes that a no-op rather than a case to detect.
      def self.columns(reach, cols)
        return [] unless reach

        first = (reach.first * cols).floor.clamp(0, cols - 1)
        last = (reach.last * cols).floor.clamp(0, cols - 1)
        (first..last).to_a
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
      # A degenerate ring -- fewer than three distinct points, or three collinear ones --
      # sums to zero and has no inside to point away from. It falls to -1 rather than +1 so
      # that "no information" agrees with every other default in the codebase (Surface's own
      # `outward:`, the hand-laid winding, a party wall), which keeps a broken ring drawing
      # what an unwound one draws instead of mirroring its pipes on its own.
      def self.outward(ring)
        area = ring.each_with_index.sum { |(x1, z1), i| x2, z2 = ring[(i + 1) % ring.length]; x1 * z2 - x2 * z1 }
        area.negative? ? 1 : -1
      end
    end
  end
end
