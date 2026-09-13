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
      KINDS = %i[wall partition floor roof gable].freeze

      attr_reader :kind, :storey, :material, :origin, :u, :v, :normal,
                  :width, :height, :cols, :rows, :thickness, :patches, :piece_offset

      def initialize(kind:, storey:, material:, origin:, u:, v:, width:, height:,
                     cols:, rows:, thickness:, patches: [], piece_offset: 0)
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

      # The material at one cell: the last patch covering it wins, so a lintel laid over a
      # window opening reads as the lintel.
      def material_at(row, col)
        patch = patches.reverse.find { |p| p.covers?(row, col) }
        patch ? Materials.fetch(patch.material) : material
      end

      def with_offset(offset)
        self.class.new(
          kind: kind, storey: storey, material: material, origin: origin, u: u, v: v,
          width: width, height: height, cols: cols, rows: rows, thickness: thickness,
          patches: patches, piece_offset: offset
        )
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
          # Per cell, worked out once here rather than repeated for every cell on the wire.
          hp: material.health_for(cell_area, thickness),
          kg: material.mass_for(cell_area, thickness),
          str: material.structural_weight,
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
