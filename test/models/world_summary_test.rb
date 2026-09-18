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
end
