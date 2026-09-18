require "test_helper"

class WorldObjectTest < ActiveSupport::TestCase
  def world
    @world ||= World.create!(
      slug: "objects", name: "Objects", bounds: [ 0, 0, 4, 4 ], spawns: [],
      content_digest: "abc123def456"
    )
  end

  def build(**overrides)
    world.world_objects.new({
      cx: 0, cz: 0, kind: "building", name: "house-1",
      x: 10.0, y: 0.0, z: 10.0, radius: 8.0, recipe: {}
    }.merge(overrides))
  end

  test "a plausible object is valid" do
    assert_predicate build, :valid?
  end

  test "kinds are closed" do
    assert_not build(kind: "spaceship").valid?
  end

  # The chunk holding an object's anchor owns it outright. That only works if the object
  # cannot reach further than a chunk: a three-by-three ring around the player is what
  # guarantees everything nearby has been loaded, and an object wider than a chunk could
  # intrude from outside it.
  test "an object wider than a chunk is rejected" do
    world.update!(chunk_size: 125)
    object = build(radius: 200.0)

    assert_not object.valid?
    assert_match(/smaller than the 125m chunk size/, object.errors[:radius].first)
  end

  test "names are unique within a world" do
    build.save!

    assert_not build.valid?, "a duplicate name would split one object's damage across two rows"
  end

  test "the same name in another world is fine" do
    build.save!
    other = World.create!(
      slug: "other", name: "Other", bounds: [ 0, 0, 1, 1 ], spawns: [],
      content_digest: "def456abc123"
    )

    assert_predicate other.world_objects.new(
      cx: 0, cz: 0, kind: "building", name: "house-1",
      x: 0.0, y: 0.0, z: 0.0, radius: 8.0, recipe: {}
    ), :valid?
  end

  test "objects are found by chunk" do
    build(name: "here", cx: 1, cz: 2).save!
    build(name: "elsewhere", cx: 9, cz: 9).save!

    assert_equal [ "here" ], world.world_objects.in_chunk(1, 2).pluck(:name)
  end

  test "a hand-made building is drawn in the default palette" do
    assert_equal "brown_brick", world_objects(:targets_house).to_building[:palette]
  end

  test "a recipe's palette ships with its building" do
    house = world_objects(:targets_house)
    house.recipe = house.recipe.merge("palette" => "red_brick")

    assert_equal "red_brick", house.to_building[:palette]
  end
end
