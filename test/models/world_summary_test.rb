require "test_helper"

class WorldSummaryTest < ActiveSupport::TestCase
  test "a world describes itself from what is actually in it" do
    assert_equal "ground, 3 crates, pillar, building", worlds(:targets).summary
  end

  test "a world with only ground says so" do
    assert_equal "ground", worlds(:flat).summary
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
  test "a building's stored piece count matches what it generates" do
    house = world_objects(:targets_house)

    assert_equal house.surface_set.piece_count, house.piece_count
    assert_equal house.surface_set.storey_count, house.storey_count
  end
end
