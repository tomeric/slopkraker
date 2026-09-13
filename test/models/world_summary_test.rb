require "test_helper"

class WorldSummaryTest < ActiveSupport::TestCase
  test "a world describes itself from what is actually in it" do
    assert_equal "ground, 3 crates, pillar", worlds(:targets).summary
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
end
