require "test_helper"

class Game::Building::RubbleTest < ActiveSupport::TestCase
  # The same house the generator's worked example uses, so the two cannot drift apart.
  def recipe(**overrides)
    Game::Building::Recipe.from({
      footprint: [ [ 0, 0 ], [ 12, 0 ], [ 12, 15 ], [ 0, 15 ] ],
      storeys: 3, storey_height: 3.0, eaves: 9.0, ridge: 12.75,
      roof: "gable", cell: 1.0, seed: 7
    }.merge(overrides))
  end

  def surface(**overrides)
    Game::Building::Rubble.build(recipe(**overrides)).first
  end

  def pile_count(set)
    set.rows.times.sum do |row|
      set.cols.times.count { |col| set.material_at(row, col).name == :rubble }
    end
  end

  test "the grid covers the footprint in coarse cells" do
    set = surface

    assert_equal :rubble, set.kind
    assert_equal 6, set.cols, "12m of footprint in 2m cells"
    assert_equal 8, set.rows, "15m of footprint in 2m cells, rounded up"
  end

  # Which is what the design asks for: enough to make the site a job, few enough that the
  # job is a pleasure.
  test "a house leaves roughly forty piles" do
    assert_in_delta 40, pile_count(surface), 8
  end

  # The whole reason positions agree in multiplayer without a byte on the wire. Every
  # client generates from the same recipe, so the same seed must give the same piles.
  test "piles are deterministic in the seed" do
    same = surface(seed: 7)
    again = surface(seed: 7)

    same.rows.times do |row|
      same.cols.times do |col|
        assert_equal same.material_at(row, col).name, again.material_at(row, col).name
      end
    end
  end

  test "a different seed lays the piles out differently" do
    seven = surface(seed: 7)
    eight = surface(seed: 8)

    differences = seven.rows.times.sum do |row|
      seven.cols.times.count { |col| seven.material_at(row, col).name != eight.material_at(row, col).name }
    end

    assert_operator differences, :>, 0, "the seed changed nothing"
  end

  # It lies flat on the ground rather than standing up like a wall, and it is below every
  # real storey so that no sweep in the collapse rule can reach it.
  test "the grid lies on the ground, below every storey" do
    set = surface

    assert_equal(-1, set.storey)
    assert_in_delta 0.0, set.origin.y, 0.001
    assert_in_delta Game::Building::Rubble::HEIGHT, set.thickness, 0.001
  end

  # A house gutted to the ground leaves all of it; one that lost only its top floor leaves
  # a third. Reserved for the maximum either way, because piece_count is a property of the
  # recipe and is stored on the row.
  test "how much is revealed scales with how much came down" do
    set = surface
    total = pile_count(set)

    assert_equal total,
                 Game::Building::Rubble.revealed_count(set, storey_count: 3, collapsed_from: 0)
    assert_in_delta total / 3.0,
                    Game::Building::Rubble.revealed_count(set, storey_count: 3, collapsed_from: 2), 1.0
    assert_equal 0,
                 Game::Building::Rubble.revealed_count(set, storey_count: 3, collapsed_from: nil)
  end

  # A building is rarely a rectangle, and rubble has no business out on the pavement.
  test "no pile sits outside the footprint" do
    l_shaped = surface(footprint: [ [ 0, 0 ], [ 12, 0 ], [ 12, 6 ], [ 6, 6 ], [ 6, 15 ], [ 0, 15 ] ])

    l_shaped.rows.times do |row|
      l_shaped.cols.times do |col|
        next unless l_shaped.material_at(row, col).name == :rubble

        x = 0.0 + (col + 0.5) * Game::Building::Rubble::CELL
        z = 0.0 + (row + 0.5) * Game::Building::Rubble::CELL
        refute(x > 6 && z > 6, "a pile landed in the notch of the L at #{x}, #{z}")
      end
    end
  end
end
