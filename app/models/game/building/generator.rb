module Game
  module Building
    # A recipe in, a set of surfaces out. Orchestration only -- walls, openings, interiors
    # and roofs each know their own job.
    #
    # THE ORDER BELOW IS THE CONTRACT. Piece offsets are handed out by walking the
    # surfaces in sequence, so reordering these four calls renumbers every piece after the
    # change. A building that had been damaged and was then regenerated in a different
    # order would come back with its damage applied to the wrong pieces -- a hole in the
    # roof where there had been one in a wall. The worked example in the tests pins the
    # order, and the world's content digest is what stops a client holding indices from a
    # previous generation.
    module Generator
      def self.call(recipe)
        recipe = Recipe.from(recipe) unless recipe.is_a?(Recipe)
        openings = Openings.new(seed: recipe.seed)

        built = Walls.build(recipe, openings: openings) + Interior.build(recipe) + Roof.build(recipe)

        SurfaceSet.new(
          built +
            # LAST, and this is the contract rather than a preference. Offsets are handed
            # out by walking surfaces in sequence, so a surface inserted anywhere earlier
            # renumbers every piece after it -- and damage recorded against a wall would
            # come back applied to the roof. Last is the only position that leaves every
            # existing index exactly where it was, which is what let this be added to a
            # world that had already been played and damaged.
            # Handed what the building is made of, because that is what its wreckage is.
            Rubble.build(recipe, built),
          storey_count: recipe.storeys
        )
      end
    end
  end
end
