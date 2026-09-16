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
      # what a house costs. The lump is the dust the building's own chunks sit in now, and
      # every material's chunks add a pool of their own on top, so twelve is plenty.
      SHAPES = 12

      # How much broken masonry swells as it breaks. Rubble does not pack back into the
      # space the wall occupied: roughly half as much again.
      BULK = 1.5

      # And how much of that is still in the way afterwards.
      #
      # Be honest about what this number is doing. A three-storey house is 353 cubic metres
      # of material and 559 tonnes of it, so all of it bulked is 530 cubic metres -- and
      # spread over the footprint alone that is three metres deep wall to wall, which is a
      # hill rather than a pile. A share stays and the rest is taken to have gone to dust,
      # which the shards a collapse throws are already selling.
      #
      # The share is a picture, not an obstacle. The truck's wheel rays pass through heaps
      # and the blade breaks whatever it meets, so how tall the pile stands is a question
      # of what a fallen house should look like and nothing else. At 0.25 the worked
      # example peaked at 1.75m, which was a pile for a bungalow under a twelve metre ridge.
      # All of it. Spread over the footprint and its ragged skirt the bulked volume comes
      # to about 1.8m on the worked example, and the rounded cone the client mounds it into
      # peaks at three metres and still stands a metre tall most of the way to the rim --
      # a storey of wreckage with shoulders, which is what a three-storey house leaves.
      # Anything less, spread this wide, thinned the shoulders into a mat.
      SHARE = 1.0

      # Only used by a building made of nothing, which cannot happen, but a zero depth
      # would make a heap with no height and no health at all.
      MINIMUM_DEPTH = 0.25

      # How far past the walls the wreckage can spread, in metres. A building does not fall
      # neatly into its own outline: the walls topple outward and the pile skirts the
      # footprint, and a pile that stopped dead at the line of the walls read as a house
      # that had sunk into its own cellar. The grid covers the footprint grown by this on
      # every side, and a cell holds a heap when its centre is inside the footprint or
      # within REACH of one of its edges -- so an L-shaped house skirts its notch as well as
      # its outside, and rubble still has no business out on the road.
      #
      # Changing it changes piece_count for every building. Update the stored counts in
      # place rather than reseeding: a reseed replaces every world row, hand-made ones
      # included, and orphans the matches that were played on them.
      MARGIN = 3.0

      # How far the skirt actually reaches at a given cell, as a share of MARGIN, drawn per
      # cell from the seed between this and one. A skirt that reached the full margin
      # everywhere had a dead straight edge, because every cell of the grown grid held a
      # heap and the outline was the grid. Drawn per cell, the far cells thin out raggedly
      # -- a cell two metres out is covered about half the time, one at three almost never
      # -- while the first metre beyond the walls is always covered, so the skirt never
      # opens a gap against the pile itself.
      REACH_FLOOR = 0.35

      EAST = Vector3.new(1, 0, 0)
      SOUTH = Vector3.new(0, 0, 1)

      # `built` is everything the building is made of. The heaps are sized from it, so a
      # bigger building leaves a bigger mess -- for ever, and without anybody choosing a
      # number. A constant here would pile a bungalow and a tower block identically.
      def self.build(recipe, built = [])
        cols = cells(recipe.width + 2 * MARGIN)
        rows = cells(recipe.depth + 2 * MARGIN)
        gaps = gaps(recipe, cols, rows)
        piles = cols * rows - gaps.length
        depth = depth_for(built, piles * CELL * CELL)
        # Centred on the footprint: the grid is whole cells, so it overshoots the grown
        # box, and the overshoot is split between the two sides rather than all on one.
        origin_x = recipe.min_x - (cols * CELL - recipe.width) / 2.0
        origin_z = recipe.min_z - (rows * CELL - recipe.depth) / 2.0

        [ Surface.new(
          kind: :rubble,
          storey: -1,
          material: Materials.fetch(:rubble),
          # Lifted by half its depth so a heap SITS ON the ground. Cells are centred on
          # their surface plane, which is right for a wall -- its thickness straddles the
          # line its origin describes -- and buries a heap to its waist.
          origin: Vector3.new(origin_x, depth / 2.0, origin_z),
          u: EAST,
          v: SOUTH,
          width: cols * CELL,
          height: rows * CELL,
          cols: cols,
          rows: rows,
          thickness: depth,
          patches: gaps,
          seed: recipe.seed,
          # What the heaps are drawn from: the building's own materials, in proportion.
          mix: mix_for(built)
        ) ]
      end

      # How deep the wreckage lies: the building's own material, swollen by breaking, the
      # share of it that stays, spread over THE GROUND THE WRECKAGE COVERS -- the footprint
      # and its margin, as the heaps actually occupy it.
      #
      # Over the ground and not over the lumps, because the lumps overlap by design and
      # overlapping lumps do not stack their heights -- they interpenetrate. Dividing by the
      # lumps' own area assumes they sit side by side, and under that assumption widening
      # them makes them thinner, which is how a field of debris turns back into a floor of
      # tiles. What the material comes to over the ground is the honest figure, and for the
      # worked example it is about 1.2m, mounded by the client to some three at the centre.
      def self.depth_for(built, ground_area)
        return MINIMUM_DEPTH if ground_area <= 0

        kept = material_volume(built) * BULK * SHARE
        [ kept / ground_area, MINIMUM_DEPTH ].max
      end

      # Every cubic metre the building is made of, by material. Voids are holes and weigh
      # nothing, and rubble is excluded because a building's wreckage cannot be made of
      # itself.
      def self.volumes_by_material(built)
        volumes = Hash.new(0.0)

        Array(built).each do |surface|
          next if surface.kind == :rubble

          surface.rows.times do |row|
            surface.cols.times do |col|
              material = surface.material_at(row, col)
              next if material.name == :void

              volumes[material.name] += surface.cell_area * surface.thickness
            end
          end
        end

        volumes
      end

      def self.material_volume(built)
        volumes_by_material(built).values.sum
      end

      # What the wreckage is drawn from: each material's share of the building's volume,
      # largest first. Sorted with the name as tie-break so the order is total, because the
      # client walks it in sequence to pick a chunk's material and two clients have to walk
      # the same list.
      def self.mix_for(built)
        volumes = volumes_by_material(built)
        total = volumes.values.sum
        return [] if total <= 0

        volumes.sort_by { |name, volume| [ -volume, name ] }
               .map { |name, volume| [ name, volume / total ] }
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
        return false unless covered?(recipe, row, col)

        draw(recipe.seed, row, col) < DENSITY
      end

      # Whether the wreckage reaches this cell: its centre, in world coordinates, is inside
      # the footprint ring or within this cell's own reach of one of its edges. A building
      # is rarely a rectangle, and the skirt follows its outline rather than its bounding
      # box. The reach is drawn per cell from the seed, which is what makes the skirt
      # ragged -- and deterministic, so every client and the server agree which heaps exist.
      def self.covered?(recipe, row, col)
        cols = cells(recipe.width + 2 * MARGIN)
        rows = cells(recipe.depth + 2 * MARGIN)
        x = recipe.min_x - (cols * CELL - recipe.width) / 2.0 + (col + 0.5) * CELL
        z = recipe.min_z - (rows * CELL - recipe.depth) / 2.0 + (row + 0.5) * CELL

        contains?(recipe.footprint, x, z) || distance_to_ring(recipe.footprint, x, z) <= reach(recipe.seed, row, col)
      end

      # A different salt from the density draw, or the two would agree cell for cell.
      def self.reach(seed, row, col)
        MARGIN * (REACH_FLOOR + (1.0 - REACH_FLOOR) * draw(seed + 977, row, col))
      end

      # How far a point is from the nearest edge of the footprint.
      def self.distance_to_ring(footprint, x, z)
        footprint.each_with_index.map do |(x1, z1), index|
          x2, z2 = footprint[(index + 1) % footprint.length]
          distance_to_segment(x, z, x1, z1, x2, z2)
        end.min
      end

      def self.distance_to_segment(px, pz, x1, z1, x2, z2)
        dx = x2 - x1
        dz = z2 - z1
        length2 = dx * dx + dz * dz
        t = length2.zero? ? 0.0 : (((px - x1) * dx + (pz - z1) * dz) / length2).clamp(0.0, 1.0)
        Math.hypot(px - (x1 + t * dx), pz - (z1 + t * dz))
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
