require "test_helper"

class Game::Damage::ObjectStateTest < ActiveSupport::TestCase
  def house
    Game::Building::Generator.call({
      footprint: [ [ 0, 0 ], [ 12, 0 ], [ 12, 15 ], [ 0, 15 ] ],
      storeys: 3, storey_height: 3.0, eaves: 9.0, ridge: 12.75,
      roof: "gable", cell: 1.0, seed: 7
    })
  end

  def state(set = house, **options)
    Game::Damage::ObjectState.new(
      surfaces: set, piece_count: set.piece_count,
      rules: Game::Spec.default_rules, **options
    )
  end

  def indices_of(surfaces)
    surfaces.flat_map { |s| (s.piece_offset...(s.piece_offset + s.piece_count)).to_a }
  end

  # A brick cell at this size is worth 4.38 health, so a small knock dents it and a big
  # one takes it out. The server runs the same absorb the client does, from the same table.
  test "a small hit dents a piece without breaking it" do
    object = state

    assert_empty object.apply(0, 2.0, "impact")
    assert object.standing?(0)
    assert_predicate object.partial, :any?
  end

  test "enough damage breaks the piece" do
    object = state

    assert_equal [ 0 ], object.apply(0, 500.0, "impact")
    refute object.standing?(0)
    assert_equal [ 0 ], object.broken
  end

  # Brick shrugs 1.0 off every hit, so a 2.0 knock lands 1.0 and the 4.38 cell takes five
  # of them. Four is deliberately just short: it proves the damage is being carried between
  # hits rather than each one being weighed against full health on its own.
  test "damage accumulates across separate hits" do
    object = state
    4.times { object.apply(0, 2.0, "impact") }

    assert object.standing?(0), "four knocks should not quite do it"
    assert_equal [ 0 ], object.apply(0, 2.0, "impact"), "the fifth should"
  end

  # Monotone: the piece is already gone, so a later hit is a no-op rather than a second
  # break event that every client would apply twice.
  test "a broken piece cannot break again" do
    object = state
    object.apply(0, 500.0, "impact")

    assert_empty object.apply(0, 500.0, "impact")
  end

  # Without the bounds check a malformed index writes into another object's bitset.
  test "an index outside the object is ignored rather than fatal" do
    object = state

    assert_empty object.apply(999_999, 500.0, "impact")
    assert_empty object.apply(-1, 500.0, "impact")
    assert_empty object.broken
  end

  # A doorway is a real piece index holding void. There is nothing there to break, and
  # crediting a hit against it would let a client report damage to thin air.
  test "a void cell cannot be damaged" do
    set = house
    object = state(set)
    void = (0...set.piece_count).find { |i| set.material_at(i)&.name == :void }

    assert void, "the canonical house should have openings"
    assert_empty object.apply(void, 500.0, "impact")
    assert object.standing?(void)
  end

  test "the material decides what a hit is worth" do
    set = house
    object = state(set)
    glass = (0...set.piece_count).find { |i| set.material_at(i)&.name == :glass }

    assert glass, "the canonical house should have windows"
    assert_equal [ glass ], object.apply(glass, 3.0, "impact"),
                 "glass should go on a knock that only dents brick"
  end

  test "settle brings a storey down once its walls are gone" do
    set = house
    object = state(set)
    walls = set.for_storey(0).select { |s| s.kind == :wall }.first(2)
    indices_of(walls).each { |index| object.apply(index, 500.0, "impact") }

    assert_equal 0, object.settle
    assert_equal 0, object.collapsed_from
    roof = set.surfaces.find { |surface| surface.kind == :roof }
    refute object.standing?(roof.piece_offset), "the roof should have come down too"
  end

  test "settle reports nothing when the building still stands" do
    assert_nil state.settle
  end

  test "collapsed_from is never raised" do
    set = house
    object = state(set, collapsed_from: 0)
    indices_of(set.surfaces.select { |s| s.storey >= 1 }).each do |index|
      object.apply(index, 500.0, "impact")
    end

    object.settle
    assert_equal 0, object.collapsed_from
  end

  test "it restores from the columns it was stored in" do
    set = house
    stored = state(set)
    stored.apply(0, 500.0, "impact")
    stored.apply(1, 2.0, "impact")

    restored = Game::Damage::ObjectState.new(
      surfaces: set, piece_count: set.piece_count, rules: Game::Spec.default_rules,
      destroyed: stored.destroyed_blob, partial: stored.partial, collapsed_from: nil
    )

    assert_equal stored.broken, restored.broken
    refute restored.standing?(0)
    assert_in_delta stored.partial[1], restored.partial[1], 1e-9
  end

  # The partial column comes back from JSON with string keys. If those are not cast, every
  # reload silently restores a damaged piece to full health.
  test "it restores partial damage stored with string keys" do
    set = house
    restored = state(set, partial: { "1" => 0.5 })

    assert_equal [ 1 ], restored.apply(1, 2.0, "impact"),
                 "a piece on half a point of health should not survive a real hit"
  end

  test "it knows whether it has anything worth writing down" do
    object = state

    refute_predicate object, :dirty?
    object.apply(0, 500.0, "impact")
    assert_predicate object, :dirty?
    object.clean!
    refute_predicate object, :dirty?
  end

  def rubble_surface(set) = set.surfaces.find { |surface| surface.kind == :rubble }
  def first_pile(set) = Game::Building::Rubble.pile_indices(rubble_surface(set)).first

  def flatten!(set, object)
    walls = set.for_storey(0).select { |s| s.kind == :wall }.first(2)
    indices_of(walls).each { |index| object.apply(index, 500.0, "impact") }
    object.settle
  end

  # A pile that does not exist yet cannot be cleared. Without this a client could report
  # damage to dormant rubble and have the house arrive already tidied up -- and because
  # breaking is monotone, there would be no way to put it back.
  test "damage to a pile is dropped while the building is still standing" do
    set = house
    object = state(set)

    assert_empty object.apply(first_pile(set), 5_000.0, "impact")
    assert object.standing?(first_pile(set)), "a dormant pile was cleared"
  end

  test "a pile clears once the building has come down on top of it" do
    set = house
    object = state(set)
    flatten!(set, object)

    assert_equal 0, object.collapsed_from, "the house did not collapse, so there is no rubble"
    assert_equal [ first_pile(set) ], object.apply(first_pile(set), 5_000.0, "impact")
    refute object.standing?(first_pile(set)), "the pile did not clear"
  end

  # Monotone, like everything else here: a cleared pile stays cleared, and settling again
  # cannot bring it back.
  test "a cleared pile is not restored by a later settle" do
    set = house
    object = state(set)
    flatten!(set, object)
    object.apply(first_pile(set), 5_000.0, "impact")

    object.settle
    refute object.standing?(first_pile(set)), "clearing was undone"
  end
end
