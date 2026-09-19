module Game
  module Building
    # One flat face of a building, as a grid of cells: a storey of one exterior wall, an
    # interior partition, a floor deck, a roof plane, a gable end.
    #
    # The grid is the whole trick. A building is not stored as pieces and is never sent as
    # pieces -- it is sent as a handful of surfaces, and the cells are implied. Twenty or
    # so surfaces describe what would otherwise be two hundred and fifty pieces, and the
    # client expands them with arithmetic that cannot drift because there is nothing in it
    # to get wrong.
    #
    # THE RULE THAT MAKES THAT SAFE: piece index space is never culled. Every row and
    # column has an index whether or not anything is drawn there. A doorway is a real
    # index holding `void`; a gable's clipped corners are real indices holding `void`. If
    # culling changed the numbering, Ruby and JavaScript would both have to cull
    # identically forever, and the first divergence would silently renumber every piece in
    # the building -- so damage recorded against one wall would come back applied to
    # another.
    class Surface
      KINDS = %i[wall partition floor roof gable hedge rubble].freeze

      attr_reader :kind, :storey, :material, :origin, :u, :v, :normal,
                  :width, :height, :cols, :rows, :thickness, :patches, :piece_offset, :seed,
                  :mix, :bay, :between, :bays, :fittings, :outward, :capped

      def initialize(kind:, storey:, material:, origin:, u:, v:, width:, height:,
                     cols:, rows:, thickness:, patches: [], piece_offset: 0, seed: 0, mix: nil,
                     bay: 0, between: nil, bays: nil, fittings: true, outward: -1, capped: false)
        @kind = kind
        @storey = storey
        @material = material
        @origin = origin
        @u = u
        @v = v
        @normal = u.cross(v).normalised
        @width = width.to_f
        @height = height.to_f
        @cols = cols
        @rows = rows
        @thickness = thickness.to_f
        @patches = patches
        @piece_offset = piece_offset
        @seed = seed
        # Only a rubble surface carries one: what the building was made of, by share of its
        # volume, largest first. The client draws a heap's chunks from it in that order.
        @mix = mix
        # The part of the building this surface stands or falls with (0 unless a building
        # has more than one bay). A party wall instead names the two bays it is shared
        # between, and belongs to neither exclusively; `bays` gives a bay per cell for a
        # surface -- a foundation strip, say -- that itself spans more than one.
        @bay = bay.to_i
        @between = between&.map(&:to_i)
        @bays = bays
        # Whether this surface gets rainwater goods drawn on it -- a gutter along a roof's
        # eaves, a downpipe at a wall's corner. True everywhere except a dakkapel's four
        # surfaces and a chimney's four walls: see #to_spec for why the generator decides
        # rather than the client.
        @fittings = fittings
        # The sign that turns a WALL's own u x v normal into a vector pointing away from the
        # building. Meaningless off a wall built from a footprint ring; see
        # Game::Building::Walls.outward for how a ring's own winding decides it, and #to_spec
        # for why -1 is the default that ships no key.
        @outward = outward
        # Whether this surface's cells were clipped back to a slope, leaving a STEP that the
        # client fills in by drawing. Set by the two places that call Roof.clip -- a gable
        # end and a pyramid's planes -- because the clip is what causes it. See #to_spec.
        @capped = capped
      end

      def piece_count = cols * rows

      def piece_index(row, col)
        piece_offset + row * cols + col
      end

      # Inverts piece_index. Used by the server to find which surface a reported index
      # belongs to, and by tests to prove the two agree.
      def local_index(piece_index)
        piece_index - piece_offset
      end

      def covers?(piece_index)
        local = local_index(piece_index)
        local >= 0 && local < piece_count
      end

      def cell_width = width / cols
      def cell_height = height / rows
      def cell_area = cell_width * cell_height

      # How much of this surface actually holds something up: cell area weighted by the
      # material in each cell, so a window and an empty doorway weigh nothing. With a
      # block, only the cells it accepts are counted -- which is how the collapse rule
      # asks what is left standing without a second traversal that could disagree.
      def structural_area
        rows.times.sum do |row|
          cols.times.sum do |col|
            next 0.0 if block_given? && !yield(piece_index(row, col))

            material_at(row, col).structural_weight * cell_area
          end
        end
      end

      # The material at one cell: the last patch covering it wins, so a lintel laid over a
      # window opening reads as the lintel.
      def material_at(row, col)
        patch = patches.reverse.find { |p| p.covers?(row, col) }
        patch ? Materials.fetch(patch.material) : material
      end

      # Every material that appears anywhere on this surface.
      def materials
        ([ material ] + patches.map { |patch| Materials.fetch(patch.material) }).uniq(&:name)
      end

      def per_material
        materials.to_h { |m| [ m.name.to_s, yield(m) ] }
      end

      def with_offset(offset)
        self.class.new(
          kind: kind, storey: storey, material: material, origin: origin, u: u, v: v,
          width: width, height: height, cols: cols, rows: rows, thickness: thickness,
          patches: patches, piece_offset: offset, seed: seed, mix: mix,
          bay: bay, between: between, bays: bays, fittings: fittings, outward: outward, capped: capped
        )
      end

      # A party wall: supports the bays on both sides of it and is felled by neither.
      def shared? = !between.nil?

      # The same surface turned about the world's y axis, which is how a building generated
      # in its own frame is put down at its real bearing. Origin, u and v turn; every count,
      # index, patch and material is untouched, because a rotation is a picture and the
      # indices are the contract.
      def rotated(yaw)
        return self if yaw.zero?

        c = Math.cos(yaw)
        s = Math.sin(yaw)
        turn = ->(vec) { Vector3.new(vec.x * c - vec.z * s, vec.y, vec.x * s + vec.z * c) }
        self.class.new(
          kind: kind, storey: storey, material: material, origin: turn.call(origin), u: turn.call(u), v: turn.call(v),
          width: width, height: height, cols: cols, rows: rows, thickness: thickness,
          patches: patches, piece_offset: piece_offset, seed: seed, mix: mix, bay: bay, between: between, bays: bays,
          fittings: fittings, outward: outward, capped: capped
        )
      end

      # Which cells break together. Worked out after the offset is known, because the
      # tiling is seeded from it -- two surfaces with identical grids should not come out
      # with identical blocks.
      def blocks
        @blocks ||= Blocks.tile(self, seed: seed)
      end

      def to_spec
        {
          kind: kind.to_s,
          storey: storey,
          mat: material.name.to_s,
          # Geometry only. Nothing on the client derives health or mass from these; hp and
          # kg ship precomputed by the one method the server also calls.
          o: origin.to_a.map { |f| f.round(5) },
          u: u.to_a.map { |f| f.round(5) },
          v: v.to_a.map { |f| f.round(5) },
          n: normal.to_a.map { |f| f.round(5) },
          w: width.round(3),
          h: height.round(3),
          cols: cols,
          rows: rows,
          t: thickness.round(3),
          off: piece_offset,
          # The client lays rubble out from this. Two players seeing heaps in the same
          # place depends entirely on both deriving them from the same seed, so a surface
          # that did not carry its own seed would have every building's wreckage laid out
          # identically -- which passes for one building and fails for a street.
          seed: seed,
          # Per cell, per material -- not per surface. A window is a glass cell in a brick
          # wall, and giving it the wall's health would make it as hard to break as the
          # wall, which is the opposite of the point. Keyed by name and covering the
          # surface's own material plus every material any patch introduces.
          hp: per_material { |m| m.health_for(cell_area, thickness) },
          kg: per_material { |m| m.mass_for(cell_area, thickness) },
          str: per_material(&:structural_weight),
          # One block id per cell, row-major, or absent where the plain grid is right.
          blocks: blocks,
          patches: patches.map(&:to_spec)
        }.tap do |spec|
          # Only when there is one. A wall shipping an empty mix would be a wall the client
          # has to ask a question of that it has no answer to.
          spec[:mix] = mix.map { |name, share| [ name.to_s, share.round(4) ] } if mix
          # Omitted at their defaults, same reasoning as mix: a plain single-bay building
          # should gain no key in a spec that three seeded worlds already compare byte for
          # byte in their tests.
          spec[:bay] = bay unless bay.zero?
          spec[:between] = between if between
          spec[:bays] = bays if bays
          # A dakkapel and a chimney are surfaces of the building like any other, but a
          # gutter belongs under the tiles of the roof itself and a downpipe against the
          # wall of the house, not round a zinc box on the slope or a stack 0.9 m square --
          # so the generator says which surfaces carry rainwater goods, and the client is
          # never trusted to infer it from kind or material.
          spec[:fittings] = false unless fittings
          # A wall's stored normal is u x v, and whether that points out of the building or
          # into it depends on which way its footprint ring was wound -- a question only the
          # generator can answer, because an imported ring's winding is whatever PostGIS gave
          # us. -1 is the default because every wall this codebase lays out by hand is wound
          # so that u x v points in; shipped only when a ring turned out the other way.
          spec[:out] = 1 if outward.positive?
          # A clipped surface stops SHORT of the roof over it, in whole cells, and what is
          # left between the stair and the slope is filled by the client with a box and a
          # wedge -- drawing, hung on the cell below, costing no index. Which surfaces leave
          # such a step is the generator's to say: a gable end always does, a pyramid's four
          # planes do, and every other roof plane in the game is a plain rectangle that does
          # not. The client can no more infer that from kind than it can infer #fittings --
          # a pyramid's planes are `roof`, exactly as a dwelling's unclipped ones are.
          # Shipped only where it is true, which is a few surfaces of the several hundred a
          # world has.
          spec[:caps] = true if capped
        end
      end

      # A rectangle of cells whose material differs from the surface's own: a window, a
      # door, a lintel, the clipped corner of a gable. Inclusive at both ends.
      class Patch
        attr_reader :col0, :row0, :col1, :row1, :material

        def initialize(col0:, row0:, col1:, row1:, material:)
          @col0 = col0
          @row0 = row0
          @col1 = col1
          @row1 = row1
          @material = material.to_sym
        end

        def covers?(row, col)
          row.between?(row0, row1) && col.between?(col0, col1)
        end

        def to_spec
          [ col0, row0, col1, row1, material.to_s ]
        end
      end
    end
  end
end
