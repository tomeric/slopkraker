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

      def self.partition(recipe, storey)
        across_z = recipe.ridge_along_z?
        origin = if across_z
          Vector3.new(recipe.min_x, storey * recipe.storey_height, recipe.min_z + recipe.depth / 2)
        else
          Vector3.new(recipe.min_x + recipe.width / 2, storey * recipe.storey_height, recipe.min_z)
        end
        span = across_z ? recipe.width : recipe.depth

        Surface.new(
          kind: :partition,
          storey: storey,
          material: Materials.fetch(:plaster),
          origin: origin,
          u: across_z ? EAST : SOUTH,
          v: UP,
          width: span,
          height: recipe.storey_height,
          cols: Walls.cells(span, recipe.cell),
          rows: Walls.cells(recipe.storey_height, recipe.cell),
          thickness: PARTITION_THICKNESS
        )
      end
    end
  end
end
