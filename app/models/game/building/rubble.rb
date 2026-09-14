module Game
  module Building
    # What a building leaves on the ground once it has finished falling down.
    #
    # One surface, lying flat over the footprint, whose cells are heaps of garbage. It is a
    # Surface and not a new concept on purpose: `at`, `material_at`, `cell_area`,
    # `piece_index`, `covers?`, the client's expansion, the instanced mesh pools and the
    # collider arrays then all work with no change whatever, and a pile is addressed over
    # the wire by exactly the `[object_id, piece_index]` pair a wall panel is.
    #
    # The piles exist from the moment the building is generated and are DORMANT until it
    # falls -- reserved index space, the same idea that makes a doorway a real index
    # holding `void`, extended to something that arrives later rather than never. Reserving
    # the maximum is what keeps piece_count a property of the recipe alone, which it has to
    # be, because it is stored on the row and bounds-checks every index a client reports.
    #
    # STOREY -1 IS LOAD-BEARING. Every sweep in Damage::Collapse is bounded below by a real
    # storey: fell_from asks each_cell(from: storey) with storey >= 0, mass_above asks
    # from: storey + 1, for_storey matches exactly, and lowest_failing only ever iterates
    # (0...ceiling). A surface below every storey is outside all four, so a collapse can
    # neither destroy, nor weigh, nor be held up by the wreckage it is in the act of making.
    module Rubble
      # Coarse against the building's own 1m: a pile is a heap you bully through, not a
      # panel. Six by eight over a twelve by fifteen house.
      CELL = 2.0
      # Share of in-footprint cells holding a pile. ONE: every square of ground the building
      # stood on gets debris on it. Anything less leaves holes in the mound by construction,
      # and a hole in a pile of rubble reads as a pocket of air rather than as variety --
      # the irregularity belongs in the shapes and their overlap, not in whether a square
      # got anything at all.
      DENSITY = 1.0
      # How much of its cell a heap covers -- OVER one, deliberately, so lumps are wider
      # than the grid they are laid out on and overlap their neighbours by construction.
      # A lump is 3.2m across on a 2m grid, so between them they cover the footprint twice
      # over and the grid stops being visible at all.
      #
      # At 0.85 they covered 58% of the site, which read as lumps scattered on a floor
      # rather than as a floor buried. A house does not fall down and leave most of its own
      # ground showing.
      #
      # Shipped to the client as `rules.collapse.rubble.scale` from this constant, so the
      # two cannot disagree about how big a lump is.
      SPREAD = 1.59

      # How many different lumps there are to go round. They cost a draw call each, but the
      # pools are shared by every building in the world -- so this is what a city costs, not
      # what a house costs, and it can afford to be generous.
      SHAPES = 16

      # How much broken masonry swells as it breaks. Rubble does not pack back into the
      # space the wall occupied: roughly half as much again.
      BULK = 1.5

      # And how much of that is still in the way afterwards.
      #
      # Be honest about what this number is doing. A three-storey house is 353 cubic metres
      # of material and 559 tonnes of it, so the truthful answer is 530 cubic metres over a
      # 180 square metre footprint -- nearly THREE METRES DEEP, wall to wall. That is not a
      # pile you clear, it is a hill you cannot get onto, and it would bury the car that
      # knocked it down.
      #
      # So a share stays and the rest is taken to have gone to dust. Which is not entirely
      # a fiction: the shards a collapse throws are carrying that material away in front of
      # you as it lands, and they fade rather than settling.
      #
      # At 0.6 the mound peaks around 4.5m with a rim under half a metre. That centre is
      # genuinely impassable -- taller than anything else in the game -- so getting through
      # a collapsed house means clearing a path rather than driving round it. That is the
      # point: it is wreckage that has to be cleared.
      SHARE = 0.6

      # Only used by a building made of nothing, which cannot happen, but a zero depth
      # would make a heap with no height and no health at all.
      MINIMUM_DEPTH = 0.25

      EAST = Vector3.new(1, 0, 0)
      SOUTH = Vector3.new(0, 0, 1)

      # `built` is everything the building is made of. The heaps are sized from it, so a
      # bigger building leaves a bigger mess -- for ever, and without anybody choosing a
      # number. A constant here would pile a bungalow and a tower block identically.
      def self.build(recipe, built = [])
        cols = cells(recipe.width)
        rows = cells(recipe.depth)
        gaps = gaps(recipe, cols, rows)
        depth = depth_for(built, recipe.footprint_area)

        [ Surface.new(
          kind: :rubble,
          storey: -1,
          material: Materials.fetch(:rubble),
          # Lifted by half its depth so a heap SITS ON the ground. Cells are centred on
          # their surface plane, which is right for a wall -- its thickness straddles the
          # line its origin describes -- and buries a heap to its waist.
          origin: Vector3.new(recipe.min_x, depth / 2.0, recipe.min_z),
          u: EAST,
          v: SOUTH,
          width: cols * CELL,
          height: rows * CELL,
          cols: cols,
          rows: rows,
          thickness: depth,
          patches: gaps,
          seed: recipe.seed
        ) ]
      end

      # How deep the wreckage lies: the building's own material, swollen by breaking, the
      # share of it that stays, spread over THE GROUND THE BUILDING STOOD ON.
      #
      # Over the footprint and not over the lumps, because the lumps overlap by design and
      # overlapping lumps do not stack their heights -- they interpenetrate. Dividing by the
      # lumps' own area assumes they sit side by side, and under that assumption widening
      # them makes them thinner, which is how a field of debris turns back into a floor of
      # tiles. What the material comes to over the footprint is the honest figure, and for
      # this house it is 0.88m, mounded by the client to about 1.5m at the centre.
      def self.depth_for(built, footprint_area)
        return MINIMUM_DEPTH if footprint_area <= 0

        kept = material_volume(built) * BULK * SHARE
        [ kept / footprint_area, MINIMUM_DEPTH ].max
      end

      # Every cubic metre the building is made of. Voids are holes and weigh nothing.
      def self.material_volume(built)
        Array(built).sum do |surface|
          next 0.0 if surface.kind == :rubble

          surface.rows.times.sum do |row|
            surface.cols.times.sum do |col|
              next 0.0 if surface.material_at(row, col).name == :void

              surface.cell_area * surface.thickness
            end
          end
        end
      end

      # How many of the piles a collapse from `collapsed_from` actually leaves. A house
      # gutted to the ground leaves all of them; one that lost only its top floor leaves a
      # proportional share. Nil means nothing has collapsed and there is no rubble at all.
      #
      # Both sides compute this from numbers they already hold -- the storey count, and
      # collapsed_from, which is monotone and already persisted -- so it never goes on the
      # wire.
      def self.revealed_count(surface, storey_count:, collapsed_from:)
        return 0 if collapsed_from.nil? || storey_count.to_i <= 0

        fell = storey_count - collapsed_from
        (total_piles(surface) * fell.to_f / storey_count).round
      end

      # The piles OUTWARD FROM THE MIDDLE, which is the order they are revealed in. Wreckage
      # piles up where the building stood, so a half-collapsed house leaves a mound in the
      # middle rather than a ring around its edge.
      #
      # This order is shared with the client and not merely the count of it. The server
      # gates damage on the revealed prefix, so a client revealing a different subset would
      # show you heaps you cannot clear and hide heaps the server thinks are there -- and
      # for a partial collapse it would do so permanently, because collapsed_from never
      # moves back.
      #
      # Distance is quantised before sorting and ties fall back to the index. Two languages
      # agreeing on a float comparison is not something to rest a shared order on.
      def self.pile_indices(surface)
        piles = surface.rows.times.flat_map do |row|
          surface.cols.times.filter_map do |col|
            next unless surface.material_at(row, col).name == :rubble

            [ (radius(surface, row, col) * 1_000_000).round, surface.piece_index(row, col) ]
          end
        end

        piles.sort.map(&:last)
      end

      # How far a cell sits from the middle of the grid, as a share of its half-extent: 0 in
      # the middle, 1 at the corners.
      def self.radius(surface, row, col)
        Math.hypot(
          (col + 0.5) / surface.cols.to_f - 0.5,
          (row + 0.5) / surface.rows.to_f - 0.5
        )
      end

      def self.total_piles(surface) = pile_indices(surface).length

      # Empty cells, one void patch each. Expressed as the gaps rather than as the piles
      # because there are fewer of them, and because it leaves the surface's own material
      # saying what the surface IS.
      def self.gaps(recipe, cols, rows)
        rows.times.flat_map do |row|
          cols.times.filter_map do |col|
            next if pile?(recipe, row, col)

            Surface::Patch.new(col0: col, row0: row, col1: col, row1: row, material: :void)
          end
        end
      end

      def self.pile?(recipe, row, col)
        return false unless inside?(recipe, row, col)

        draw(recipe.seed, row, col) < DENSITY
      end

      # The cell's centre, in world coordinates, tested against the footprint ring. A
      # building is rarely a rectangle, and rubble has no business on the pavement.
      def self.inside?(recipe, row, col)
        contains?(
          recipe.footprint,
          recipe.min_x + (col + 0.5) * CELL,
          recipe.min_z + (row + 0.5) * CELL
        )
      end

      # Ray casting, the standard even-odd test. The footprint is a closed ring of points.
      def self.contains?(footprint, x, z)
        inside = false

        footprint.each_with_index do |(x1, z1), index|
          x2, z2 = footprint[(index + 1) % footprint.length]
          next unless (z1 > z) != (z2 > z)

          inside = !inside if x < x1 + (z - z1) / (z2 - z1) * (x2 - x1)
        end

        inside
      end

      # A cheap deterministic hash, in the spirit of Openings#window_columns: the same
      # inputs give the same answer forever, which is the entire reason two players see
      # rubble in the same place. Never Random, never a time, never an object id.
      def self.draw(seed, row, col)
        h = (seed.to_i + 1) * 73_856_093
        h ^= (row + 1) * 19_349_663
        h ^= (col + 1) * 83_492_791
        (h.abs % 10_000) / 10_000.0
      end

      def self.cells(length)
        [ (length / CELL).ceil, 1 ].max
      end
    end
  end
end
