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
      # Share of in-footprint cells holding a pile rather than nothing. Not 1.0, so the site
      # reads as scattered wreckage rather than as the grid it is actually on.
      DENSITY = 0.85
      # Knee high.
      HEIGHT = 0.5

      EAST = Vector3.new(1, 0, 0)
      SOUTH = Vector3.new(0, 0, 1)

      def self.build(recipe)
        cols = cells(recipe.width)
        rows = cells(recipe.depth)

        [ Surface.new(
          kind: :rubble,
          storey: -1,
          material: Materials.fetch(:rubble),
          origin: Vector3.new(recipe.min_x, 0.0, recipe.min_z),
          u: EAST,
          v: SOUTH,
          width: cols * CELL,
          height: rows * CELL,
          cols: cols,
          rows: rows,
          thickness: HEIGHT,
          patches: gaps(recipe, cols, rows),
          seed: recipe.seed
        ) ]
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

      # The piles in index order, which is the order they are revealed in.
      def self.pile_indices(surface)
        surface.rows.times.flat_map do |row|
          surface.cols.times.filter_map do |col|
            surface.piece_index(row, col) if surface.material_at(row, col).name == :rubble
          end
        end
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
