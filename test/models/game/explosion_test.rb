require "test_helper"

class Game::ExplosionTest < ActiveSupport::TestCase
  def explosion(**overrides)
    Game::Explosion.new(**{
      radius: 4.0, expand_time: 0.2, linger: 0.1,
      prop_push: 0.9, prop_lift: 0.6,
      vehicle_share: 0.6, vehicle_lift: 0.8
    }.merge(overrides))
  end

  # --- the shell expands -------------------------------------------------------

  test "starts as a point" do
    assert_in_delta 0.0, explosion.radius_at(0), 1e-9
  end

  test "reaches its full radius by the end of the expansion" do
    assert_in_delta 4.0, explosion.radius_at(0.2), 1e-9
  end

  test "never grows past its radius however long it hangs around" do
    assert_in_delta 4.0, explosion.radius_at(10.0), 1e-9
  end

  # Eased out rather than linear: a blast should leap outward and settle, not creep at a
  # constant rate. Only the timing changes -- damage is a function of distance, so the
  # curve cannot move the numbers.
  test "leaps outward early and eases into its final radius" do
    assert_operator explosion.radius_at(0.1), :>, 2.0
  end

  test "an explosion with no expansion time is already at full radius" do
    assert_in_delta 4.0, explosion(expand_time: 0.0).radius_at(0), 1e-9
  end

  # --- force falls off with distance -------------------------------------------

  test "hits hardest at the centre" do
    assert_in_delta 1.0, explosion.force_at(0), 1e-9
  end

  test "falls to nothing at the rim" do
    assert_in_delta 0.0, explosion.force_at(4.0), 1e-9
  end

  test "is worth nothing at all beyond the rim" do
    assert_in_delta 0.0, explosion.force_at(9.0), 1e-9
  end

  test "falls off evenly between the centre and the rim" do
    assert_in_delta 0.5, explosion.force_at(2.0), 1e-9
  end

  # --- what it shoves ----------------------------------------------------------
  #
  # A car caught in a blast gets shoved, but only a share of what the same blast does to
  # loose scenery. Being launched across the arena by a stray rocket stops being funny
  # very quickly.

  test "shoves a car by a share of what it does to the world" do
    assert_in_delta 0.9 * 0.6, explosion.vehicle_push, 1e-9
  end

  test "never shoves a car harder than the scenery" do
    assert_operator explosion.vehicle_push, :<, explosion.prop_push
  end

  # --- lifetime ----------------------------------------------------------------

  test "lives long enough to expand and then linger" do
    assert_in_delta 0.3, explosion.duration, 1e-9
  end

  test "serialises the numbers the client needs" do
    spec = explosion.to_spec

    assert_in_delta 4.0, spec[:radius], 1e-9
    assert_in_delta 0.2, spec[:expand_time], 1e-9
    assert_in_delta 0.1, spec[:linger], 1e-9
    assert_in_delta 0.9, spec[:prop_push], 1e-9
    assert_in_delta 0.6, spec[:prop_lift], 1e-9
    assert_in_delta 0.6, spec[:vehicle_share], 1e-9
    assert_in_delta 0.9 * 0.6, spec[:vehicle_push], 1e-9
    assert_in_delta 0.8, spec[:vehicle_lift], 1e-9
  end

  test "carries a colour so the client need not invent one" do
    assert_not_nil explosion.to_spec[:colour]
  end
end
