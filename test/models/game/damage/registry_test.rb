require "test_helper"

class Game::Damage::RegistryTest < ActiveSupport::TestCase
  setup do
    Game::Damage::Registry.reset!
    @world = World.find_by!(slug: "targets")
    @match = Match.start(key: "registry-test", world: @world)
    @house = @world.world_objects.find_by!(kind: "building")
  end

  teardown { Game::Damage::Registry.reset! }

  def broken_count(match)
    Game::Damage::Registry.checkout(match) do |state|
      state.state_for([ @house.id ]).first["broken_count"]
    end
  end

  def break_piece(match, index)
    Game::Damage::Registry.checkout(match) do |state|
      state.apply_batch([ [ @house.id, index, 500.0, "impact" ] ])
    end
  end

  test "the same match gets the same state back" do
    first = Game::Damage::Registry.checkout(@match) { |state| state.object_id }
    second = Game::Damage::Registry.checkout(@match) { |state| state.object_id }

    assert_equal first, second
  end

  test "different matches do not share wreckage" do
    other = Match.start(key: "registry-other", world: @world)
    break_piece(@match, 0)

    assert_equal 0, broken_count(other), "one match's damage must not show up in another"
  end

  test "releasing writes the wreckage down" do
    break_piece(@match, 0)

    Game::Damage::Registry.release(@match)

    assert_equal 1, ObjectDamage.where(match: @match).count
  end

  test "a released match comes back from its rows" do
    break_piece(@match, 0)
    Game::Damage::Registry.release(@match)

    assert_equal 1, broken_count(@match)
  end

  # Two threads hammering the same match must not interleave inside a batch.
  test "concurrent checkouts do not lose damage" do
    threads = 4.times.map { |n| Thread.new { break_piece(@match, n) } }
    threads.each(&:join)

    assert_operator broken_count(@match), :>=, 4, "every thread's break should have landed"
  end
end
