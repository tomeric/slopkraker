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

      # Every bay in the building: the part of it that stands or falls together. A single
      # house is one bay; a terrace is one per dwelling; a church one per part. Rubble is
      # left out -- it belongs to no bay's structure -- and a shared wall belongs to both
      # of its neighbours.
      def bays
        surfaces.reject { |s| s.kind == :rubble }.flat_map { |s| s.between || [ s.bay ] }.uniq.sort
      end

      # What the collapse rule weighs for one bay: its own surfaces, and the shared walls
      # it leans on.
      def for_bay(bay)
        {
          own: surfaces.select { |s| s.kind != :rubble && !s.shared? && s.bay == bay },
          shared: surfaces.select { |s| s.shared? && s.between.include?(bay) }
        }
      end

      # What the collapse rule weighs: the load-bearing area of one storey. Glass and empty
      # doorways contribute nothing, so a wall of windows holds nothing up. With a block,
      # only the cells it accepts -- which is how Damage::Collapse asks what is still up.
      def structural_area(storey, &standing)
        for_storey(storey).sum do |surface|
          next 0.0 unless Damage::Collapse::LOAD_BEARING.include?(surface.kind)

          surface.structural_area(&standing)
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
