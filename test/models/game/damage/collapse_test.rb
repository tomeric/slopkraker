require "test_helper"

class Game::Damage::CollapseTest < ActiveSupport::TestCase
  # The same canonical house the generator test and the targets fixture use, so the
  # collapse rule is exercised against the building people actually drive into rather
  # than against one shaped to make the rule look good.
  def house(**overrides)
    Game::Building::Generator.call({
      footprint: [ [ 0, 0 ], [ 12, 0 ], [ 12, 15 ], [ 0, 15 ] ],
      storeys: 3, storey_height: 3.0, eaves: 9.0, ridge: 12.75,
      roof: "gable", cell: 1.0, seed: 7
    }.merge(overrides))
  end

  def rules(**overrides)
    Game::Spec.default_rules.fetch(:collapse).merge(overrides)
  end

  def evaluate(set, broken:, **options)
    rules = options.delete(:rules) || self.rules
    Game::Damage::Collapse.evaluate(surfaces: set, broken: broken, rules: rules, **options)
  end

  def walls_at(set, storey)
    set.for_storey(storey).select { |surface| surface.kind == :wall }
  end

  def indices_of(*surfaces)
    surfaces.flatten.flat_map { |s| (s.piece_offset...(s.piece_offset + s.piece_count)).to_a }
  end

  def above(set, storey)
    set.surfaces.select { |surface| surface.storey >= storey }
  end

  # Every piece index across these surfaces whose material the block accepts.
  def cells_of(set, surfaces)
    surfaces.flat_map do |surface|
      surface.rows.times.flat_map do |row|
        surface.cols.times.filter_map do |col|
          surface.piece_index(row, col) if yield(surface.material_at(row, col))
        end
      end
    end
  end

  test "an untouched building stands" do
    result = evaluate(house, broken: [])

    assert_empty result.collapsed
    assert_empty result.broken
  end

  # The rule the driver reads: take out half the shell of the ground floor and the house
  # comes down on top of you. What makes it fire here is not the count of walls but their
  # size measured against the weight they were holding up.
  test "knocking out two walls of the ground floor brings it down" do
    set = house
    result = evaluate(set, broken: indices_of(walls_at(set, 0).first(2)))

    assert_equal 0, result.collapsed[0]
  end

  test "one wall gone is not enough" do
    set = house
    result = evaluate(set, broken: indices_of(walls_at(set, 0).first(1)))

    assert_empty result.collapsed
  end

  # The point of weighing support against load rather than counting walls: strip the
  # weight off the top first and the same two walls no longer bring the shell down. A
  # house with nothing left above its ground floor is a shell, and a shell stands.
  test "the same two walls hold once the storeys above them are gone" do
    set = house
    stripped = indices_of(above(set, 1)) + indices_of(walls_at(set, 0).first(2))

    result = evaluate(set, broken: stripped, collapsed: { 0 => 1 })

    assert_equal 1, result.collapsed[0], "the ground floor should not follow the storeys above it"
  end

  # Perforating rather than removing: every wall loses its middle band, which is a real
  # bite out of what holds the storey up but leaves each wall doing most of its job.
  test "perforating the middle of every wall leaves the storey standing" do
    set = house
    broken = walls_at(set, 0).flat_map do |surface|
      middle = surface.rows / 2
      (1...(surface.cols - 1)).map { |col| surface.piece_index(middle, col) }
    end

    result = evaluate(set, broken: broken)

    assert_empty result.collapsed, "a perforated storey should still hold"
  end

  # The backstop, and the reason the ratio alone is not enough. A top storey carries
  # almost nothing, so no load ratio would ever condemn it -- but a storey with its walls
  # gone cannot hold its own roof up, and a roof left hanging in the air is the most
  # visible bug this whole feature could ship.
  test "a storey that is mostly gone fails even with nothing above it" do
    set = house
    gutted = indices_of(walls_at(set, 2)) + indices_of(above(set, 3))

    result = evaluate(set, broken: gutted, collapsed: {})

    assert_equal 2, result.collapsed[0], "a gutted top storey cannot hold its own roof"
  end

  # Everything at or above the failed storey goes, roof and gables included -- they carry
  # storey_count, which is above every real storey, so "storey >= s" reaches them.
  test "a collapse destroys every piece at or above the failed storey" do
    set = house
    result = evaluate(set, broken: indices_of(walls_at(set, 0).first(2)))

    assert_equal 0, result.collapsed[0]
    building_pieces = indices_of(set.surfaces.reject { |s| s.kind == :rubble })
    assert_equal building_pieces.length,
                 (result.broken + indices_of(walls_at(set, 0).first(2))).uniq.length,
                 "a collapse from the ground up should account for every piece in the " \
                 "building -- but not for the rubble it leaves behind"

    roof = set.surfaces.find { |surface| surface.kind == :roof }
    assert_includes result.broken, roof.piece_index(0, 0), "the roof should come down with it"
  end

  # What a storey landing on the one below it should sort out: the masonry holds and the
  # light stuff does not. A pancake that took the brick with it would make every collapse
  # reach the ground, and a pancake that took nothing would be an integer the server keeps
  # to itself.
  test "a collapse leaves the brickwork below it standing" do
    set = house
    result = evaluate(set, broken: indices_of(walls_at(set, 1).first(3)))

    assert_equal 1, result.collapsed[0]

    brick = cells_of(set, walls_at(set, 0)) { |material| material.name == :brick }
    assert_empty result.broken & brick, "brickwork should hold under a storey landing on it"
  end

  test "a collapse shakes the light material out of the storey below" do
    set = house
    flimsy = cells_of(set, set.for_storey(0)) { |material| material.name.in?(%i[plaster timber]) }

    result = evaluate(set, broken: indices_of(walls_at(set, 1).first(3)))

    assert_operator (result.broken & flimsy).length, :>, 0,
                    "plaster and timber should not survive a storey landing on them"
  end

  # Monotone downward, never up. A building already collapsed from storey 1 has nothing
  # standing above it, so re-evaluating must not "discover" a higher failure and report a
  # collapse that would un-destroy the storey below.
  test "collapsed_from is never raised" do
    set = house
    result = evaluate(set, broken: indices_of(above(set, 1)), collapsed: { 0 => 1 })

    assert_equal 1, result.collapsed[0]
    assert_empty result.broken, "nothing is left above storey 1 to destroy twice"
  end

  # The pancake. A storey already worn down does not survive what lands on it, which is
  # what makes a failure partway up sometimes reach the ground.
  test "a falling storey can bring down one already worn thin beneath it" do
    set = house
    worn = walls_at(set, 0).to_h { |surface| [ surface, indices_of(surface) ] }
    health = worn.flat_map { |surface, indices|
      left = surface.material.health_for(surface.cell_area, surface.thickness) * 0.2
      indices.map { |index| [ index, left ] }
    }.to_h

    result = evaluate(set, broken: indices_of(walls_at(set, 1).first(3)), health: health)

    assert_equal 0, result.collapsed[0], "the pancake should have finished the ground floor"
  end

  # The same collapse onto the same storey at full health stops one floor up. The only
  # difference between this and the test above is how worn the ground floor was, which is
  # the whole point of the pancake carrying damage rather than a verdict.
  test "the same falling storey stops above a ground floor in good repair" do
    set = house
    result = evaluate(set, broken: indices_of(walls_at(set, 1).first(3)))

    assert_equal 1, result.collapsed[0]
  end

  test "a pancake stops at a storey that can take it" do
    set = house
    result = evaluate(set, broken: indices_of(walls_at(set, 2)) + indices_of(above(set, 3)))

    assert_equal 2, result.collapsed[0], "an intact ground floor should not follow"
  end

  # Pancake damage that does not break a cell still has to be remembered, or the next
  # storey to land on it starts from full health again and nothing ever accumulates.
  test "a pancake leaves the storey below damaged rather than untouched" do
    set = house
    result = evaluate(set, broken: indices_of(walls_at(set, 2)) + indices_of(above(set, 3)))

    assert_predicate result.health, :any?, "the storey below should carry the dent"

    set.surfaces.each do |surface|
      result.health.each_key do |index|
        next unless surface.covers?(index)

        assert_equal 1, surface.storey, "only the storey under the collapse takes the pancake"
      end
    end
  end

  # THE failure mode of this whole design. A collapse sweeps every cell of every surface at
  # or above the failed storey, so rubble left visible to it would be destroyed by the very
  # collapse that creates it -- and nothing downstream would look wrong. A house would
  # simply never leave any wreckage, and no message, row or assertion would say why.
  test "a collapse leaves the rubble it creates standing" do
    set = house
    rubble = set.surfaces.last
    result = evaluate(set, broken: indices_of(walls_at(set, 0).first(2)))

    piles = Game::Building::Rubble.pile_indices(rubble)
    assert_operator piles.length, :>, 0, "the house generated no rubble to test with"
    assert_empty(result.broken & piles, "the collapse destroyed its own wreckage")
  end

  # Rubble weighs nothing and holds nothing up, so a building reserving it cannot change
  # when that building falls down. If this drifts, every collapse in the game retunes
  # itself silently.
  test "rubble is weighed neither as load nor as support" do
    rubble = house.surfaces.last

    assert_equal :rubble, rubble.kind
    assert_equal 0.0, rubble.structural_area, "rubble counted as support"
    assert_equal(-1, rubble.storey, "rubble must sit below every storey the rule sweeps")
  end

  # Two dwellings of 6 x 9 m sharing a party wall, one storey of 3 m, 1 m cells, no
  # openings, built by hand so the arithmetic can be followed: each bay owns a front and a
  # back wall of 18 cells; the party wall is 27 cells and is half of each bay's support.
  def pair
    brick = Game::Materials.fetch(:brick)
    east, south, up = Game::Vector3.new(1, 0, 0), Game::Vector3.new(0, 0, 1), Game::Vector3.new(0, 1, 0)
    wall = lambda do |x0, z0, x1, z1, bay: 0, between: nil|
      along = Game::Vector3.new(x1 - x0, 0, z1 - z0)
      Game::Building::Surface.new(
        kind: :wall, storey: 0, material: brick, origin: Game::Vector3.new(x0, 0, z0), u: along.normalised, v: up,
        width: along.length, height: 3.0, cols: along.length.round, rows: 3, thickness: 0.3, bay: bay, between: between
      )
    end
    roof = lambda do |x0, bay|
      Game::Building::Surface.new(
        kind: :roof, storey: 1, material: Game::Materials.fetch(:roof_tile), origin: Game::Vector3.new(x0, 3.0, 0),
        u: east, v: south, width: 6.0, height: 9.0, cols: 6, rows: 9, thickness: 0.2, bay: bay
      )
    end
    Game::Building::SurfaceSet.new([
      wall.call(0, 0, 6, 0, bay: 0), wall.call(6, 9, 0, 9, bay: 0),
      wall.call(6, 0, 12, 0, bay: 1), wall.call(12, 9, 6, 9, bay: 1),
      wall.call(6, 0, 6, 9, between: [ 0, 1 ]),
      roof.call(0, 0), roof.call(6, 1)
    ], storey_count: 1)
  end

  def bay_walls(set, bay) = set.for_bay(bay)[:own].select { |s| s.kind == :wall }
  def party(set) = set.surfaces.find(&:shared?)

  test "a pair is two bays sharing one wall" do
    assert_equal [ 0, 1 ], pair.bays
    assert_equal [ party(pair).piece_offset ], pair.for_bay(1)[:shared].map(&:piece_offset)
  end

  test "taking the front and back out of one dwelling drops that dwelling and no other" do
    set = pair
    result = evaluate(set, broken: indices_of(bay_walls(set, 1)))

    assert_equal({ 1 => 0 }, result.collapsed)
    assert_includes result.broken, set.for_bay(1)[:own].find { |s| s.kind == :roof }.piece_offset, "the bay's own roof comes down"
    assert_not_includes result.broken, party(set).piece_offset, "a shared wall is never felled by a bay"
    assert_empty result.broken & indices_of(set.for_bay(0)[:own]), "the neighbour is untouched"
  end

  test "the front alone is not enough" do
    set = pair
    result = evaluate(set, broken: indices_of(bay_walls(set, 1).first))

    assert_empty result.collapsed
  end

  # A party wall is half of each neighbour's support: losing it hurts both, and finishing
  # either one then takes only its front.
  test "a party wall gone weakens both neighbours" do
    set = pair
    assert_empty evaluate(set, broken: indices_of(party(set))).collapsed
    both = indices_of(party(set)) + indices_of(bay_walls(set, 0).first) + indices_of(bay_walls(set, 1).first)

    assert_equal({ 0 => 0, 1 => 0 }, evaluate(set, broken: both).collapsed)
  end

  test "a bay that has already fallen is not reported again and never rises" do
    set = pair
    result = evaluate(set, broken: indices_of(bay_walls(set, 1)), collapsed: { 1 => 0 })

    assert_equal({ 1 => 0 }, result.collapsed)
    assert_empty result.broken
  end

  # A church in miniature, generated rather than built by hand, because what is being tested
  # is that the importer's own shape -- a row of NO dwellings whose every part is a box with a
  # bay of its own -- reaches the collapse rule as separate bays. A nave of 20 x 12 m under a
  # gable, and a tower of 8 x 8 m six storeys up under a pyramid, standing six metres clear of
  # it so they share no wall.
  def church
    Game::Building::Generator.call(
      "kind" => "row", "category" => "church", "cell" => 1.0, "seed" => 3, "yaw" => 0.0,
      "band" => [ 0.0, 0.0 ], "storeys" => 6, "storey_height" => 4.0, "eaves" => 24.0, "ridge" => 24.0, "roof" => "flat",
      "dwellings" => [],
      "boxes" => [
        { "ring" => [ [ 0, 0 ], [ 20, 0 ], [ 20, 12 ], [ 0, 12 ] ], "eaves" => 8.0, "ridge" => 12.0,
          "storeys" => 2, "roof" => "gable", "door" => true, "solid" => false, "bay" => 0, "name" => "nave" },
        { "ring" => [ [ 26, 0 ], [ 34, 0 ], [ 34, 8 ], [ 26, 8 ] ], "eaves" => 24.0, "ridge" => 30.0,
          "storeys" => 6, "roof" => "pyramid", "door" => false, "solid" => false, "bay" => 1, "name" => "tower" }
      ],
      "footprint" => [ [ 0, 0 ], [ 34, 0 ], [ 34, 12 ], [ 0, 12 ] ]
    )
  end

  # The spike's third scenario, and the reason a church is not one building to this rule:
  # taking the whole ground storey out of the Sint-Marcellinus nave left 65% of the church's
  # support standing, because the tower and the chapels share its "storey 0" and hold their
  # own ground up. Weighed per bay, the nave is on its own.
  test "the nave alone collapses the nave and leaves the tower" do
    set = church
    assert_equal [ 0, 1 ], set.bays, "the church came out as one bay"
    nave = set.for_bay(0)[:own].select { |s| s.kind == :wall && s.storey.zero? }
    assert_operator nave.length, :>, 0, "the nave has no ground-storey walls"

    result = evaluate(set, broken: indices_of(nave))

    assert_equal({ 0 => 0 }, result.collapsed, "the tower was condemned with the nave, or the nave stood")
    assert_includes result.broken, set.for_bay(0)[:own].find { |s| s.kind == :roof }.piece_offset, "the nave kept its roof in the air"
    # Picked out by where they stand rather than by the bay they carry: with both parts in
    # bay 0 -- which is what a church imported as a dwelling row came out as -- `for_bay(1)`
    # is empty and an assertion made against it passes by having nothing in it.
    tower = set.surfaces.select { |s| s.kind != :rubble && s.origin.x >= 25.0 }
    assert_operator tower.length, :>, 0, "nothing stands where the tower was put"
    assert_empty result.broken & indices_of(tower), "the tower came down with the nave"
  end
end
