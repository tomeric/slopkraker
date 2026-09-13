require "test_helper"

class Game::Parts::RocketLauncherTest < ActiveSupport::TestCase
  COOLDOWN = 0.1

  def launcher
    Game::Parts::RocketLauncher.new(
      offset: Game::Vector3.new(0, 0.8, -0.6),
      size: Game::Vector3.new(0.3, 0.3, 1.0),
      cooldown: COOLDOWN,
      ammo_cost: 10.0,
      launch_angle: 12.0,
      recoil: 1200.0,
      rocket: Game::Rocket.new(
        launch_speed: 18.0, mass: 12.0, radius: 0.16, lifetime: 5.0,
        minimum_damage: 45.0, max_damage: 190.0, damage_per_speed: 2.6,
        flight: {
          coast: { drag: 9.0, gravity_scale: 0.75, min_time: 0.15, max_time: 0.9 },
          thrust: { acceleration: 58.0, max_speed: 64.0, gravity_scale: 0.30 }
        },
        explosion: Game::Explosion.new(
          radius: 4.5, expand_time: 0.22, linger: 0.20,
          prop_push: 0.9, prop_lift: 0.6, vehicle_share: 0.6, vehicle_lift: 0.8
        )
      )
    )
  end

  def full_bar
    Game::TurboBar.new(capacity: 100.0, recharge_rate: 20.0, recharge_delay: 0.35)
  end

  # "Fire 10 rockets with a full turbo bar" means ten back to back, until the bar runs
  # dry -- not ten ever. Firing at the 100ms floor keeps resetting the recharge delay,
  # so a sustained burst earns no free shots mid-burst.
  test "a full turbo bar yields exactly ten rockets in a sustained burst" do
    gun, bar = launcher, full_bar
    fired = 0

    while gun.fire(bar)
      fired += 1
      gun.update(COOLDOWN)
      bar.update(COOLDOWN)
    end

    assert_equal 10, fired
  end

  test "the bar recharges into further rockets once firing stops" do
    gun, bar = launcher, full_bar
    10.times do
      assert gun.fire(bar)
      gun.update(COOLDOWN)
      bar.update(COOLDOWN)
    end
    assert_not gun.fire(bar), "bar should be dry after ten"

    gun.update(1.0)
    bar.update(1.0)
    assert gun.fire(bar), "a second of recharge should buy at least one more rocket"
  end

  test "refuses to fire faster than the cooldown" do
    gun, bar = launcher, full_bar

    assert gun.fire(bar)
    gun.update(COOLDOWN - 0.001)
    assert_not gun.fire(bar), "fired before the 100ms cooldown elapsed"

    gun.update(0.001)
    assert gun.fire(bar)
  end

  test "refuses to fire when the bar cannot cover a rocket" do
    gun, bar = launcher, full_bar
    assert bar.draw(95.0)

    gun.update(COOLDOWN)
    assert_not gun.fire(bar)
    assert_equal 5.0, bar.level, "a refused shot must not drain the bar"
  end

  test "the recharge delay must outlast the cooldown or sustained fire earns free rockets" do
    assert_operator full_bar.recharge_delay, :>, COOLDOWN
  end

  # --- it kicks ------------------------------------------------------------------

  test "shoves the car back when it fires" do
    assert_operator launcher.recoil, :>, 0.0
  end

  test "ships the recoil so the kick can be tuned" do
    assert_in_delta 1200.0, launcher.to_spec[:recoil], 1e-9
  end
end
