require "test_helper"

class Game::Damage::MatchStateTest < ActiveSupport::TestCase
  setup do
    @world = World.find_by!(slug: "targets")
    @match = Match.start(key: "test-match", world: @world)
    @house = @world.world_objects.find_by!(kind: "building")
    @state = Game::Damage::MatchState.new(@match, rules: Game::Spec.default_rules)
  end

  def wall_hits(count)
    set = @house.surface_set
    set.for_storey(0).select { |s| s.kind == :wall }.first(count).flat_map do |surface|
      (surface.piece_offset...(surface.piece_offset + surface.piece_count)).map do |index|
        [ @house.id, index, 500.0, "impact" ]
      end
    end
  end

  test "a hit that breaks a piece is reported back" do
    result = @state.apply_batch([ [ @house.id, 0, 500.0, "impact" ] ])

    assert_equal [ [ @house.id, 0 ] ], result["broken"]
    assert_empty result["collapses"]
  end

  test "a hit that only dents reports nothing" do
    result = @state.apply_batch([ [ @house.id, 0, 1.0, "impact" ] ])

    assert_empty result["broken"]
  end

  test "an unknown object is ignored" do
    result = @state.apply_batch([ [ 999_999, 0, 500.0, "impact" ] ])

    assert_empty result["broken"]
  end

  # A crate is one dynamic body that tumbles, not a grid of pieces. Only buildings have
  # piece indices to report against.
  test "a prop has no pieces to break" do
    crate = @world.world_objects.find_by!(kind: "prop")

    assert_empty @state.apply_batch([ [ crate.id, 0, 500.0, "impact" ] ])["broken"]
  end

  # A collapse names the bay it happened in as well as the storey it came down from. A
  # single house is one bay, so bay 0 is what every hand-made world reports; a terrace
  # reports one entry per dwelling that fell, and the entries are independent.
  test "taking out two walls reports the collapse" do
    result = @state.apply_batch(wall_hits(2))

    assert_equal [ [ @house.id, 0, 0 ] ], result["collapses"]
  end

  test "the collapse is reported once, not once per hit" do
    result = @state.apply_batch(wall_hits(2))

    assert_equal 1, result["collapses"].length
  end

  # Not security -- the server cannot recompute damage without simulating -- but it bounds
  # what one malformed or malicious batch can reach.
  test "an over-long batch is truncated, and says so" do
    hits = Array.new(Game::Damage::MatchState::MAX_HITS_PER_BATCH + 1) { |i| [ @house.id, i, 500.0, "impact" ] }
    result = @state.apply_batch(hits)

    assert_equal Game::Damage::MatchState::MAX_HITS_PER_BATCH, result["broken"].length
    assert result["truncated"], "a dropped hit has to be reported, never swallowed"
    assert_equal false, @state.apply_batch([ [ @house.id, 1000, 500.0, "impact" ] ])["truncated"]
  end

  test "a single hit cannot exceed the per-hit cap" do
    huge = Game::Damage::MatchState::MAX_AMOUNT_PER_HIT * 1000
    @state.apply_batch([ [ @house.id, 0, huge, "impact" ] ])

    capped = Game::Damage::MatchState.new(@match, rules: Game::Spec.default_rules)
    capped.apply_batch([ [ @house.id, 0, Game::Damage::MatchState::MAX_AMOUNT_PER_HIT, "impact" ] ])

    assert_equal capped.state_for([ @house.id ]).first["broken"],
                 @state.state_for([ @house.id ]).first["broken"]
  end

  test "a malformed hit is dropped rather than fatal" do
    assert_nothing_raised do
      @state.apply_batch([ [ @house.id, "not-an-index", 5.0, "impact" ], nil, [ @house.id ] ])
    end
  end

  test "flushing writes a row" do
    @state.apply_batch([ [ @house.id, 0, 500.0, "impact" ] ])

    assert_equal 1, @state.flush!

    row = ObjectDamage.find_by!(match: @match, world_object: @house)
    assert_equal 1, row.broken_count
  end

  test "a restarted process picks the wreckage back up" do
    @state.apply_batch([ [ @house.id, 0, 500.0, "impact" ] ])
    @state.flush!

    fresh = Game::Damage::MatchState.new(@match, rules: Game::Spec.default_rules)
    fresh.rehydrate!

    assert_empty fresh.apply_batch([ [ @house.id, 0, 500.0, "impact" ] ])["broken"],
                 "piece 0 was already broken before the restart"
    assert_equal 1, fresh.state_for([ @house.id ]).first["broken_count"]
  end

  test "flushing twice writes nothing the second time" do
    @state.apply_batch([ [ @house.id, 0, 500.0, "impact" ] ])
    @state.flush!

    assert_equal 0, @state.flush!, "nothing changed, so nothing should be written"
  end

  test "state_for hands back what a joining client needs" do
    @state.apply_batch([ [ @house.id, 0, 500.0, "impact" ] ])

    entry = @state.state_for([ @house.id ]).first

    assert_equal @house.id, entry["id"]
    assert_equal 1, entry["broken_count"]
    assert_equal({}, entry["collapsed"], "nothing has come down, so no bay has a storey")

    @state.apply_batch(wall_hits(2))

    assert_equal({ "0" => 0 }, @state.state_for([ @house.id ]).first["collapsed"])
  end

  # The map is what survives a restart, and it survives as JSON -- so what comes back has
  # string keys and the client is handed them as it stored them.
  test "a collapse survives a restart as a map per bay" do
    @state.apply_batch(wall_hits(2))
    @state.flush!
    row = ObjectDamage.find_by!(match: @match, world_object_id: @house.id)
    assert_equal({ "0" => 0 }, row.collapsed)

    fresh = Game::Damage::MatchState.new(@match, rules: Game::Spec.default_rules)
    fresh.rehydrate!
    assert_equal({ "0" => 0 }, fresh.state_for([ @house.id ]).first["collapsed"])
  end

  # Partial health is never broadcast: darkening a damaged piece is cosmetic and local.
  test "state_for ships what is gone, never what is merely dented" do
    @state.apply_batch([ [ @house.id, 0, 1.0, "impact" ] ])

    entry = @state.state_for([ @house.id ]).first

    assert_equal 0, entry["broken_count"]
    refute entry.key?("partial"), "partial health has no business on the wire"
  end

  test "one match's damage does not leak into another" do
    other = Match.start(key: "other-match", world: @world)
    @state.apply_batch([ [ @house.id, 0, 500.0, "impact" ] ])
    @state.flush!

    fresh = Game::Damage::MatchState.new(other, rules: Game::Spec.default_rules)
    fresh.rehydrate!

    assert_equal 0, fresh.state_for([ @house.id ]).first["broken_count"]
  end
end
