require "test_helper"

class Game::RocketTest < ActiveSupport::TestCase
  def rocket(**overrides)
    Game::Rocket.new(**{
      launch_speed: 18.0, max_speed: 64.0, acceleration: 58.0, mass: 12.0, radius: 0.16,
      lifetime: 5.0, gravity_scale: 0.65, blast_radius: 4.5, minimum_damage: 45.0,
      max_damage: 190.0, damage_per_speed: 2.6
    }.merge(overrides))
  end

  test "leaves the rail well below its top speed" do
    assert_operator rocket.launch_speed, :<, rocket.max_speed / 2
  end

  test "damage rises with speed, so a rocket with room to run hits harder" do
    close_range = rocket.damage_at(rocket.launch_speed)
    long_range = rocket.damage_at(rocket.max_speed)

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
    assert_equal 0.0, rocket(acceleration: 0.0).spin_up_time
  end

  test "serialises without leaking ruby objects" do
    spec = rocket.to_spec
    assert_equal 45.0, spec[:minimum_damage]
    assert spec.values.all? { |v| v.is_a?(Numeric) || v.is_a?(String) }
  end
end
