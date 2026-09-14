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
      KINDS = %i[wall partition floor roof gable rubble].freeze

      attr_reader :kind, :storey, :material, :origin, :u, :v, :normal,
                  :width, :height, :cols, :rows, :thickness, :patches, :piece_offset, :seed

      def initialize(kind:, storey:, material:, origin:, u:, v:, width:, height:,
                     cols:, rows:, thickness:, patches: [], piece_offset: 0, seed: 0)
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
          patches: patches, piece_offset: offset, seed: seed
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
          o: origin.to_a,
          u: u.to_a,
          v: v.to_a,
          n: normal.to_a,
          w: width,
          h: height,
          cols: cols,
          rows: rows,
          t: thickness,
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
        }
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
