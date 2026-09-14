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
    Game::Building::Generator.call(recipe(**overrides)).surfaces.last
  end

  def heap_volume(set)
    piles = Game::Building::Rubble.total_piles(set)
    spread = Game::Building::Rubble::SPREAD * Game::Building::Rubble::CELL
    piles * spread * spread * set.thickness
  end

  def material_volume(**overrides)
    Game::Building::Generator.call(recipe(**overrides)).surfaces.sum do |s|
      next 0.0 if s.kind == :rubble

      s.rows.times.sum do |row|
        s.cols.times.sum do |col|
          s.material_at(row, col).name == :void ? 0.0 : s.cell_area * s.thickness
        end
      end
    end
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

  # It lies flat rather than standing up like a wall, and it is below every real storey so
  # that no sweep in the collapse rule can reach it. How deep it is is a separate question,
  # answered by what the building was made of -- see below.
  test "the grid lies flat, below every storey" do
    set = surface

    assert_equal(-1, set.storey)
    assert_equal Game::Building::Rubble::EAST, set.u
    assert_equal Game::Building::Rubble::SOUTH, set.v
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

  # What a house leaves is what a house was MADE of. A three storey house is 353 cubic
  # metres of material and 559 tonnes of it, and heaps sized by a constant would be the
  # same on a bungalow and a tower -- which is the difference between wreckage and a
  # decoration that happens to be lying where a building used to be.
  #
  # Measured as DEPTH OVER THE FOOTPRINT rather than as the sum of the lumps, because the
  # lumps overlap by design and overlapping lumps do not stack their heights. What the
  # material comes to when it is spread over the ground the house stood on is the honest
  # figure, and it is what a collapsed house actually looks like: under a metre, mounded.
  test "the heaps are as deep as the material comes to over the footprint" do
    set = surface
    kept = material_volume * Game::Building::Rubble::BULK * Game::Building::Rubble::SHARE

    assert_in_delta kept / (12.0 * 15.0), set.thickness, 0.02
  end

  # Wreckage covers the ground the building stood on. At 58% it read as scattered lumps on
  # a site rather than as the site being buried, which is the wrong picture: a house does
  # not fall down and leave most of its own floor showing.
  test "the wreckage covers the ground the house stood on" do
    set = surface
    side = Game::Building::Rubble::CELL * Game::Building::Rubble::SPREAD
    covered = Game::Building::Rubble.total_piles(set) * side * side

    assert_operator covered, :>, 12.0 * 15.0,
                    "the lumps do not between them cover the footprint even once"
  end

  # Enough shapes that a site does not read as one lump repeated. They cost a draw call
  # each, but the pools are shared by every building in the world, so this is the cost for
  # a city and not the cost per house.
  test "there are enough different lumps to go round" do
    assert_operator Game::Building::Rubble::SHAPES, :>=, 12
  end

  # The consequence that matters, and the reason this is derived rather than tuned: a
  # bigger building leaves a bigger mess, for ever, without anybody choosing a number.
  test "a taller house leaves deeper heaps on the same footprint" do
    one = surface(storeys: 1, eaves: 3.0, ridge: 5.0)
    three = surface

    assert_operator three.thickness, :>, one.thickness * 2,
                    "three storeys of material should not pile up like one"
  end

  # Cells are centred on their surface plane, which is right for a wall -- its thickness
  # straddles the line its origin describes -- and wrong for a heap on the ground, which
  # would be buried to its waist. Half of every heap was underground, and that is most of
  # why they read as paving slabs rather than as rubble.
  test "a heap sits on the ground rather than half in it" do
    set = surface

    assert_in_delta set.thickness / 2.0, set.origin.y, 0.001
  end
end
