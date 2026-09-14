module Game
  module Building
    # Everything needed to generate a building, and nothing else. A few hundred bytes,
    # stored on the world_objects row; the two hundred and fifty pieces it describes are
    # never stored anywhere.
    #
    # The fields are deliberately the ones 3DBAG already publishes -- a footprint, the
    # height of the eaves, the height of the ridge, a roof type and a storey count -- so
    # importing real buildings later is a matter of filling this in rather than of
    # teaching the generator a second vocabulary.
    class Recipe
      ROOFS = %w[gable flat].freeze
      DEFAULT_CELL = 1.5
      DEFAULT_STOREY_HEIGHT = 3.0

      class Invalid < StandardError; end

      attr_reader :footprint, :storeys, :storey_height, :eaves, :ridge, :roof, :cell, :seed

      def self.from(attributes)
        attributes = attributes.symbolize_keys
        storeys = (attributes[:storeys] || 2).to_i
        storey_height = (attributes[:storey_height] || DEFAULT_STOREY_HEIGHT).to_f
        eaves = (attributes[:eaves] || storeys * storey_height).to_f

        new(
          footprint: (attributes[:footprint] || []).map { |x, z| [ x.to_f, z.to_f ] },
          storeys: storeys,
          storey_height: storey_height,
          eaves: eaves,
          ridge: (attributes[:ridge] || eaves + 2.5).to_f,
          roof: (attributes[:roof] || "gable").to_s,
          cell: (attributes[:cell] || DEFAULT_CELL).to_f,
          seed: (attributes[:seed] || 0).to_i
        )
      end

      def initialize(footprint:, storeys:, storey_height:, eaves:, ridge:, roof:, cell:, seed:)
        @footprint = footprint
        @storeys = storeys
        @storey_height = storey_height
        @eaves = eaves
        @ridge = ridge
        @roof = roof
        @cell = cell
        @seed = seed
        validate!
      end

      def min_x = footprint.map(&:first).min
      def max_x = footprint.map(&:first).max
      def min_z = footprint.map(&:last).min
      def max_z = footprint.map(&:last).max

      def width = max_x - min_x
      def depth = max_z - min_z

      # The ridge runs along the longer axis, which is what makes a gable look like a
      # house rather than like a tent pitched sideways.
      def ridge_along_z? = depth >= width

      def rise = [ ridge - eaves, 0.0 ].max

      # The ground the building actually stands on, by the shoelace formula. Not the
      # bounding box: an L-shaped house does not stand on the square it fits inside, and
      # the wreckage it leaves has to cover what it stood on rather than what it fitted in.
      def footprint_area
        footprint.each_with_index.sum { |(x1, z1), index|
          x2, z2 = footprint[(index + 1) % footprint.length]
          x1 * z2 - x2 * z1
        }.abs / 2.0
      end

      # Edges as pairs of points, closing the ring.
      def edges
        footprint.each_with_index.map do |point, index|
          [ point, footprint[(index + 1) % footprint.length] ]
        end
      end

      private
        def validate!
          raise Invalid, "a footprint needs at least three points" if footprint.length < 3
          raise Invalid, "storeys must be positive" unless storeys.positive?
          raise Invalid, "cell size must be positive" unless cell.positive?
          raise Invalid, "roof must be one of #{ROOFS.join(", ")}" unless ROOFS.include?(roof)
          raise Invalid, "the ridge cannot sit below the eaves" if ridge < eaves
        end
    end
  end
end
