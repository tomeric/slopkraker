module Game
  module Building
    # The generated surfaces of one building, with their piece offsets assigned.
    #
    # The ORDER IS PART OF THE CONTRACT. Offsets are handed out by walking the surfaces in
    # sequence, so changing the order changes what every index after the change refers to.
    # A building that has been damaged and then regenerated in a different order would
    # come back with the damage applied to the wrong pieces -- a hole in the roof where
    # there was one in a wall. The generator fixes the order and the worked example in the
    # tests pins it.
    class SurfaceSet
      attr_reader :surfaces, :storey_count

      def initialize(surfaces, storey_count:)
        offset = 0
        @surfaces = surfaces.map do |surface|
          placed = surface.with_offset(offset)
          offset += placed.piece_count
          placed
        end.freeze
        @storey_count = storey_count
        @piece_count = offset
      end

      attr_reader :piece_count

      def surface_for(piece_index)
        surfaces.find { |surface| surface.covers?(piece_index) }
      end

      def at(piece_index)
        surface = surface_for(piece_index)
        return nil unless surface

        local = surface.local_index(piece_index)
        [ surface, local / surface.cols, local % surface.cols ]
      end

      def material_at(piece_index)
        surface, row, col = at(piece_index)
        surface&.material_at(row, col)
      end

      def for_storey(storey)
        surfaces.select { |surface| surface.storey == storey }
      end

      # What the collapse rule weighs: the load-bearing area of one storey. Glass and empty
      # doorways contribute nothing, so a wall of windows holds nothing up.
      def structural_area(storey)
        for_storey(storey).sum do |surface|
          next 0.0 unless %i[wall partition].include?(surface.kind)

          surface.rows.times.sum do |row|
            surface.cols.times.sum do |col|
              surface.material_at(row, col).structural_weight * surface.cell_area
            end
          end
        end
      end

      def to_spec
        {
          storeys: storey_count,
          piece_count: piece_count,
          surfaces: surfaces.map(&:to_spec)
        }
      end
    end
  end
end
