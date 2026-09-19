require "test_helper"

class WorldSummaryTest < ActiveSupport::TestCase
  test "a world describes itself from what is actually in it" do
    assert_equal "ground, 3 crates, pillar, building", worlds(:targets).summary
  end

  test "a world with only ground says so" do
    assert_equal "ground", worlds(:flat).summary
  end

  # An imported world is not spelled out anywhere a person can read: its rows come out of
  # the importer, and how many there are is whatever the survey had. So this asserts the
  # shape of the sentence rather than the sentence -- that a world built from recipes still
  # describes itself from what is in it, and does not come back "empty" because nothing in
  # it was hand-placed. "rows", not "buildings": `role` is the RECIPE's kind, and a terrace
  # of four dwellings is one `row`.
  test "an imported world counts the rows it was generated from" do
    assert_match(/\A\d+ rows\z/, worlds(:geleen).summary)
  end

  test "a world with nothing in it does not claim otherwise" do
    empty = World.create!(
      slug: "void", name: "Void", bounds: [ 0, 0, 1, 1 ], spawns: [],
      content_digest: "voidworld001"
    )

    assert_equal "empty", empty.summary
  end

  test "extent comes from the bounds" do
    assert_equal [ 400.0, 400.0 ], worlds(:flat).extent
  end

  # The stored counts are what the server bounds-checks a reported piece index against. If
  # they drift from what the generator actually produces, a real index gets rejected or a
  # bogus one accepted -- and neither failure says anything useful about why.
  # EVERY building, not one of them. While a single house existed anywhere this was the
  # same assertion either way; a street of twelve is twelve chances for a hand-written
  # count to be wrong, and a wrong one is silent -- the server simply starts rejecting
  # real indices for that one house, which reads as damage mysteriously not registering.
  test "every building's stored piece count matches what it generates" do
    buildings = WorldObject.where(kind: "building")
    assert_operator buildings.count, :>, 1, "this stopped covering more than one building"

    buildings.each do |building|
      set = building.surface_set
      assert_equal set.piece_count, building.piece_count,
                   "#{building.world.slug}/#{building.name} has a stale piece_count"
      assert_equal set.storey_count, building.storey_count,
                   "#{building.world.slug}/#{building.name} has a stale storey_count"
    end
  end

  test "the street is built on both sides of its road" do
    street = worlds(:street)
    houses = street.world_objects.where(kind: "building")

    assert_equal 12, houses.count
    assert_equal 6, houses.count { |house| house.x.positive? }, "the east side"
    assert_equal 6, houses.count { |house| house.x.negative? }, "the west side"
  end

  # THE EAVES CLEAR THE WALL, on every pitched plane in every world.
  #
  # `spec_test` pins `EAVES_OVERHANG > Walls::THICKNESS`, which is not the property. The
  # overhang runs DOWN THE SLOPE, so what has to beat half a wall is its horizontal
  # component, `EAVES_OVERHANG × cos(pitch)` -- and the flat-out bar implies that only
  # while `cos(pitch) > 0.5`, which is a pitch under 60°. Sint-Marcellinus is 66° and
  # clears by about 12 mm. So any value between roughly 0.31 and 0.36 would pass the pinned
  # bar and the browser test (which visits `targets`, where the margin is 2.3×) while
  # leaving the church's tiles short of its own wall. This is the assertion that would
  # catch it, and it is here rather than in `spec_test` because it needs every world's
  # buildings rather than one number.
  test "the tiles reach past the wall on every pitched plane in every world" do
    overhang = Game::Building::Roof::EAVES_OVERHANG
    need = Game::Building::Walls::THICKNESS / 2.0
    # A roof plane's v runs up the slope, so v.y is the sine of the pitch: zero on anything
    # that is really a deck. The same test the client makes before hanging a gutter, and the
    # same tolerance -- a pitch of just over one degree, which no roof has and no float
    # error reaches.
    pitched = 0.02
    planes = 0
    short = []

    World.find_each do |world|
      world.world_objects.where(kind: "building").each do |object|
        object.surface_set.surfaces.each do |surface|
          next unless surface.kind == :roof && surface.v.y.abs > pitched

          planes += 1
          reach = overhang * Math.hypot(surface.v.x, surface.v.z)
          short << [ world.slug, object.name, reach.round(4) ] if reach <= need
        end
      end
    end

    assert_operator planes, :>, 0, "no world has a pitched roof -- has the sweep stopped finding them?"
    assert_empty short, "these planes do not reach past the wall they sit on"
  end
end
