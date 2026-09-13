require "test_helper"

class Game::RocketTest < ActiveSupport::TestCase
  def rocket(**overrides)
    Game::Rocket.new(**{
      launch_speed: 18.0, mass: 12.0, radius: 0.16, lifetime: 5.0,
      minimum_damage: 45.0, max_damage: 190.0, damage_per_speed: 2.6,
      flight: flight, explosion: explosion
    }.merge(overrides))
  end

  def flight(**overrides)
    {
      coast: { drag: 9.0, gravity_scale: 0.75, ignite_climb: 2.0, min_time: 0.15, max_time: 0.9 },
      thrust: { acceleration: 58.0, max_speed: 64.0, gravity_scale: 0.30 }
    }.merge(overrides)
  end

  def explosion
    Game::Explosion.new(
      radius: 4.5, expand_time: 0.22, linger: 0.20,
      prop_push: 0.9, prop_lift: 0.6, vehicle_share: 0.6, vehicle_lift: 0.8
    )
  end

  test "leaves the rail well below its top speed" do
    assert_operator rocket.launch_speed, :<, rocket.thrust[:max_speed] / 2
  end

  test "damage rises with speed, so a rocket with room to run hits harder" do
    close_range = rocket.damage_at(rocket.launch_speed)
    long_range = rocket.damage_at(rocket.thrust[:max_speed])

    assert_operator long_range, :>, close_range * 2
  end

  test "never falls below the minimum however slowly it lands" do
    assert_equal 45.0, rocket.damage_at(0)
    assert_equal 45.0, rocket.damage_at(-30)
  end

  test "is capped so a long flight cannot run away with it" do
    assert_equal 190.0, rocket.damage_at(10_000)
  end

  test "reports how long it takes to wind up" do
    assert_in_delta (64.0 - 18.0) / 58.0, rocket.spin_up_time, 1e-9
  end

  test "a rocket that cannot accelerate never winds up" do
    stalled = rocket(flight: flight(thrust: { acceleration: 0.0, max_speed: 64.0, gravity_scale: 0.3 }))

    assert_equal 0.0, stalled.spin_up_time
  end

  # --- the coast phase ---------------------------------------------------------
  #
  # The rocket lobs out of the launcher under its own momentum, shedding speed, and only
  # lights the motor near the apex. Two arcs rather than one flat dart.

  test "sheds speed while it coasts" do
    assert_operator rocket.coast_speed_at(0.5), :<, rocket.launch_speed
  end

  test "never coasts backwards however long the coast runs" do
    assert_equal 0.0, rocket.coast_speed_at(100.0)
  end

  test "is still at launch speed the instant it leaves the rail" do
    assert_in_delta 18.0, rocket.coast_speed_at(0), 1e-9
  end

  # Fired down a slope the rocket is already falling on the first frame, so apex detection
  # alone would light the motor immediately and collapse the two arcs back into one.
  test "always coasts for a moment before it can ignite" do
    assert_operator rocket.coast[:min_time], :>, 0.0
  end

  # And fired from a fast-moving buggy the apex may never arrive at all, so there has to
  # be a point at which it lights up regardless.
  test "ignites by itself even if the apex never comes" do
    assert_operator rocket.coast[:max_time], :>, rocket.coast[:min_time]
  end

  # Waiting for the apex leaves the rocket travelling flat at launch height, and the
  # moment thrust tips its heading down it is in the dirt. It has to light while still
  # climbing, so the second arc starts with somewhere to go.
  test "lights its thrusters while it is still climbing" do
    assert_operator rocket.coast[:ignite_climb], :>, 0.0
  end

  # This is what makes the two arcs read as two arcs rather than as one long curve.
  test "arcs harder while coasting than it does under power" do
    assert_operator rocket.coast[:gravity_scale], :>, rocket.thrust[:gravity_scale]
  end

  # --- serialisation -----------------------------------------------------------

  test "ships both flight phases to the client" do
    flight = rocket.to_spec[:flight]

    assert_in_delta 9.0, flight[:coast][:drag], 1e-9
    assert_in_delta 58.0, flight[:thrust][:acceleration], 1e-9
  end

  # Every rocket carries the blast it will leave behind, serialised down to numbers.
  test "ships its explosion as plain numbers rather than an object" do
    blast = rocket.to_spec[:explosion]

    assert_kind_of Hash, blast
    assert_in_delta 4.5, blast[:radius], 1e-9
  end
end
