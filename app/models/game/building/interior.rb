module Game
  module Building
    # What is inside: storey decks, and the partitions that divide each floor.
    #
    # The building is hollow, and that is the point. A hole in an exterior wall only reads
    # as a hole because you can see through it into a room and out the far side; a solid
    # shell would just show a dark face. Everything in here exists to make the outside
    # worth breaking.
    #
    # Floors and partitions are laid out against the footprint's bounding box. For the
    # rectangular buildings generated so far that is exact. An imported footprint with a
    # kink in it would get a deck slightly larger than its outline -- noted rather than
    # solved, because solving it means clipping polygons, which is the thing this design
    # deliberately avoids.
    module Interior
      DECK_THICKNESS = 0.25
      PARTITION_THICKNESS = 0.15
      EAST = Vector3.new(1, 0, 0)
      SOUTH = Vector3.new(0, 0, 1)
      UP = Vector3.new(0, 1, 0)

      def self.build(recipe)
        decks(recipe) + partitions(recipe)
      end

      # The ground slab is concrete and everything above it is timber, which is both how
      # houses are built and a way of making the ground floor the last thing to give.
      def self.decks(recipe)
        (0...recipe.storeys).map do |storey|
          deck(recipe, storey: storey, material: storey.zero? ? :concrete : :timber)
        end
      end

      def self.deck(recipe, storey:, material:)
        Surface.new(
          kind: :floor,
          storey: storey,
          material: Materials.fetch(material),
          origin: Vector3.new(recipe.min_x, storey * recipe.storey_height, recipe.min_z),
          u: EAST,
          v: SOUTH,
          width: recipe.width,
          height: recipe.depth,
          cols: Walls.cells(recipe.width, recipe.cell),
          rows: Walls.cells(recipe.depth, recipe.cell),
          thickness: DECK_THICKNESS
        )
      end

      # One partition down the middle of each storey, running across the short axis so it
      # divides the floor into two rooms rather than two corridors.
      def self.partitions(recipe)
        (0...recipe.storeys).map { |storey| partition(recipe, storey) }
      end

      # WHERE THE PARTITION STANDS, and the only place that decides it. `partition` builds
      # the slab from this and `partition_reach` works out which walls that slab lands on
      # from the same three numbers, so the thing drawn and the columns kept clear of glass
      # for it cannot drift apart.
      #
      # `[[x, z], direction, span]` in the recipe's own frame: the corner it starts at, the
      # axis it runs along and how far. The span is the bounding box's own extent rather
      # than the distance between two endpoints, because `Walls.cells` rounds it into a
      # column count and `Math.sqrt(dx * dx)` is not `dx` to the last bit -- a piece index
      # is not worth a ulp.
      def self.partition_line(recipe)
        if recipe.ridge_along_z?
          [ [ recipe.min_x, recipe.min_z + recipe.depth / 2 ], EAST, recipe.width ]
        else
          [ [ recipe.min_x + recipe.width / 2, recipe.min_z ], SOUTH, recipe.depth ]
        end
      end

      # WHICH WALLS THE PARTITION LANDS ON, as a fraction range along each footprint edge
      # -- `[low, high]`, 0 at the edge's start and 1 at its end -- or nil for an edge it
      # never meets. One entry per edge, in `recipe.edges` order. Walls turns a range into
      # columns against its OWN grid, because a column is the wall's unit and not this
      # module's; all that is answered here is where along the wall the plaster arrives.
      #
      # A SEGMENT AGAINST A SEGMENT, never a special case per shape. "Which walls does a
      # partition meet" is obvious for a rectangle -- the two it runs between -- and that
      # obviousness is a trap: the partition is laid out against the footprint's BOUNDING
      # BOX (see the note at the top of this file), so it does not stop at the first wall it
      # meets -- it runs out over a notch and back into what is on the far side of it, and a
      # horseshoe is crossed four times. Intersecting the segments answers every shape with
      # one piece of arithmetic and no list of cases to keep complete.
      #
      # Three things the geometry actually does, each of which broke a simpler version:
      #
      # * A partition ENDS on the two walls it runs between rather than crossing them, so
      #   the crossing is at fraction 0 or 1 ALONG THE PARTITION and a strict-interior test
      #   finds nothing at all on a rectangle -- which is every hand-made building there is.
      #   Both ends are inclusive.
      # * A wall the partition is PARALLEL to is not met, whatever else the arithmetic says:
      #   the two long walls of a rectangle are exactly this, and their intersection is a
      #   division by zero rather than a column.
      # * The partition is a SLAB PARTITION_THICKNESS thick and not a line, so it lands on
      #   every column its thickness reaches -- 75 mm each side of the crossing, widened by
      #   1/sin where the two meet at an angle, because a slanted slab smears along the wall
      #   it meets. That is one column except where the crossing falls on a cell boundary,
      #   which two of the street's twelve do exactly, and there it is honestly two rather
      #   than whichever one the last bit of a float happens to pick.
      def self.partition_reach(recipe)
        (origin, direction, span) = partition_line(recipe)
        finish = [ origin[0] + direction.x * span, origin[1] + direction.z * span ]
        recipe.edges.map { |from, to| reach_along(origin, finish, from, to) }
      end

      # Within this of parallel, in the sine of the angle between them, a wall and the
      # partition have no crossing to name: the two long walls of every rectangle are
      # exactly parallel and the cross product below is their zero.
      PARALLEL = 1e-9
      # A crossing at a segment's very end is a crossing. The endpoints land on the bounding
      # box, which is where the walls are, so this is the common case rather than the corner
      # one -- and it is a tolerance on a FRACTION, so it reads the same at any size.
      TOUCHES = 1e-9

      def self.reach_along(from, to, edge_from, edge_to)
        rx, rz = to[0] - from[0], to[1] - from[1]
        sx, sz = edge_to[0] - edge_from[0], edge_to[1] - edge_from[1]
        cross = rx * sz - rz * sx
        length = Math.hypot(sx, sz)
        scale = Math.hypot(rx, rz) * length
        return nil if scale.zero? || cross.abs <= PARALLEL * scale

        qx, qz = edge_from[0] - from[0], edge_from[1] - from[1]
        along_wall = (qx * rz - qz * rx) / cross
        along_partition = (qx * sz - qz * sx) / cross
        return nil unless along_wall.between?(-TOUCHES, 1 + TOUCHES) &&
                          along_partition.between?(-TOUCHES, 1 + TOUCHES)

        # `scale / cross.abs` is 1 / sin of the angle between the two: the slab's half
        # thickness, projected onto the wall it meets.
        half = PARTITION_THICKNESS / 2 * scale / cross.abs / length
        [ along_wall - half, along_wall + half ]
      end

      def self.partition(recipe, storey)
        (x, z), direction, span = partition_line(recipe)

        Surface.new(
          kind: :partition,
          storey: storey,
          material: Materials.fetch(:plaster),
          origin: Vector3.new(x, storey * recipe.storey_height, z),
          u: direction,
          v: UP,
          width: span,
          height: recipe.storey_height,
          cols: Walls.cells(span, recipe.cell),
          rows: Walls.cells(recipe.storey_height, recipe.cell),
          thickness: PARTITION_THICKNESS,
          seed: recipe.seed
        )
      end
    end
  end
end
