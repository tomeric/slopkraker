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

    assert_nil result.collapsed_from
    assert_empty result.broken
  end

  # The rule the driver reads: take out half the shell of the ground floor and the house
  # comes down on top of you. What makes it fire here is not the count of walls but their
  # size measured against the weight they were holding up.
  test "knocking out two walls of the ground floor brings it down" do
    set = house
    result = evaluate(set, broken: indices_of(walls_at(set, 0).first(2)))

    assert_equal 0, result.collapsed_from
  end

  test "one wall gone is not enough" do
    set = house
    result = evaluate(set, broken: indices_of(walls_at(set, 0).first(1)))

    assert_nil result.collapsed_from
  end

  # The point of weighing support against load rather than counting walls: strip the
  # weight off the top first and the same two walls no longer bring the shell down. A
  # house with nothing left above its ground floor is a shell, and a shell stands.
  test "the same two walls hold once the storeys above them are gone" do
    set = house
    stripped = indices_of(above(set, 1)) + indices_of(walls_at(set, 0).first(2))

    result = evaluate(set, broken: stripped, collapsed_from: 1)

    assert_equal 1, result.collapsed_from, "the ground floor should not follow the storeys above it"
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

    assert_nil result.collapsed_from, "a perforated storey should still hold"
  end

  # The backstop, and the reason the ratio alone is not enough. A top storey carries
  # almost nothing, so no load ratio would ever condemn it -- but a storey with its walls
  # gone cannot hold its own roof up, and a roof left hanging in the air is the most
  # visible bug this whole feature could ship.
  test "a storey that is mostly gone fails even with nothing above it" do
    set = house
    gutted = indices_of(walls_at(set, 2)) + indices_of(above(set, 3))

    result = evaluate(set, broken: gutted, collapsed_from: nil)

    assert_equal 2, result.collapsed_from, "a gutted top storey cannot hold its own roof"
  end

  # Everything at or above the failed storey goes, roof and gables included -- they carry
  # storey_count, which is above every real storey, so "storey >= s" reaches them.
  test "a collapse destroys every piece at or above the failed storey" do
    set = house
    result = evaluate(set, broken: indices_of(walls_at(set, 0).first(2)))

    assert_equal 0, result.collapsed_from
    assert_equal set.piece_count, (result.broken + indices_of(walls_at(set, 0).first(2))).uniq.length,
                 "a collapse from the ground up should account for every piece in the building"

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

    assert_equal 1, result.collapsed_from

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
    result = evaluate(set, broken: indices_of(above(set, 1)), collapsed_from: 1)

    assert_equal 1, result.collapsed_from
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

    assert_equal 0, result.collapsed_from, "the pancake should have finished the ground floor"
  end

  # The same collapse onto the same storey at full health stops one floor up. The only
  # difference between this and the test above is how worn the ground floor was, which is
  # the whole point of the pancake carrying damage rather than a verdict.
  test "the same falling storey stops above a ground floor in good repair" do
    set = house
    result = evaluate(set, broken: indices_of(walls_at(set, 1).first(3)))

    assert_equal 1, result.collapsed_from
  end

  test "a pancake stops at a storey that can take it" do
    set = house
    result = evaluate(set, broken: indices_of(walls_at(set, 2)) + indices_of(above(set, 3)))

    assert_equal 2, result.collapsed_from, "an intact ground floor should not follow"
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
end
