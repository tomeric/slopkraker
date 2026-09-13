require "test_helper"

class Game::DamageResolverTest < ActiveSupport::TestCase
  MINIMUM = 4.0

  def resolver
    Game::DamageResolver.new(damage_per_speed: 2.0, minimum_speed: MINIMUM)
  end

  def blade
    Game::Parts::BulldozerBlade.new(
      offset: Game::Vector3.new(0, 0.5, 2.2),
      size: Game::Vector3.new(2.6, 0.9, 0.25),
      damage_multiplier: 2.5
    )
  end

  def bull_bar
    Game::Parts::BullBar.new(
      offset: Game::Vector3.new(0, 0.4, -1.8),
      size: Game::Vector3.new(1.8, 0.3, 0.2),
      damage_multiplier: 3.0,
      minimum_slip_angle: 0.35,
      retain: 0.1
    )
  end

  test "a nudge below the minimum speed does no damage" do
    assert_equal 0.0, resolver.resolve(part: blade, speed: MINIMUM - 0.1)
  end

  test "damage scales with speed above the minimum" do
    # (20 - 4) * 2.0 * 2.5
    assert_in_delta 80.0, resolver.resolve(part: blade, speed: 20.0), 1e-9
  end

  test "the blade multiplies damage over a bare chassis hit" do
    bare = resolver.resolve(part: nil, speed: 20.0)
    assert_operator resolver.resolve(part: blade, speed: 20.0), :>, bare
  end

  test "the bull bar only multiplies while drifting" do
    sliding = resolver.resolve(part: bull_bar, speed: 20.0, state: { drifting: true, slip_angle: 0.6 })
    rolling = resolver.resolve(part: bull_bar, speed: 20.0, state: { drifting: false, slip_angle: 0.6 })

    assert_in_delta 96.0, sliding, 1e-9
    assert_in_delta 32.0, rolling, 1e-9
    assert_operator sliding, :>, rolling
  end

  test "negative closing speed never yields negative damage" do
    assert_equal 0.0, resolver.resolve(part: blade, speed: -30.0)
  end

  # --- what you hit, not only what you hit it with -------------------------------

  test "a material with no hardness and no multiplier changes nothing" do
    plain = Game::Material.new(name: :plain, health_per_m2: 1.0, density: 1.0, colour: "#ffffff")

    assert_in_delta resolver.resolve(part: nil, speed: 20.0),
                    resolver.resolve(part: nil, speed: 20.0, material: plain), 1e-9
  end

  test "glass takes far more from the same hit than concrete" do
    glass = resolver.resolve(part: nil, speed: 20.0, material: Game::Materials.fetch(:glass))
    concrete = resolver.resolve(part: nil, speed: 20.0, material: Game::Materials.fetch(:concrete))

    assert_operator glass, :>, concrete * 3
  end

  # Hardness is why bumping a pier is pointless however fast you are going, and it has to
  # come off after the multipliers or a good enough part would cancel it out.
  test "hardness is subtracted after the multipliers" do
    hard = Game::Material.new(
      name: :hard, health_per_m2: 1.0, density: 1.0, colour: "#ffffff",
      hardness: 10.0, multipliers: { impact: 2.0 }
    )
    raw = resolver.resolve(part: nil, speed: 20.0)

    assert_in_delta raw * 2.0 - 10.0, resolver.resolve(part: nil, speed: 20.0, material: hard), 1e-9
  end

  # The floor. Something a car cannot out-damage should be a very long job, not a
  # permanently invincible one -- a player has no way to tell those apart, and "I hit it
  # a hundred times and nothing happened" is indistinguishable from a bug.
  test "a fraction of every hit lands however hard the target is" do
    floored = Game::DamageResolver.new(damage_per_speed: 2.0, minimum_speed: 4.0, minimum_fraction: 0.1)
    stubborn = Game::Material.new(
      name: :stubborn, health_per_m2: 1.0, density: 1.0, colour: "#ffffff", hardness: 10_000.0
    )
    raw = floored.resolve(part: nil, speed: 20.0)

    landed = floored.resolve(part: nil, speed: 20.0, material: stubborn)
    assert_in_delta raw * 0.1, landed, 1e-9
    assert_operator landed, :>, 0
  end

  test "with no floor configured hardness can still absorb a hit entirely" do
    assert_equal 0.0, resolver.resolve(part: nil, speed: 5.0, material: Game::Materials.fetch(:steel))
  end

  test "the damage kind changes what a material takes" do
    concrete = Game::Materials.fetch(:concrete)
    impact = resolver.resolve(part: nil, speed: 30.0, material: concrete, kind: :impact)
    blast = resolver.resolve(part: nil, speed: 30.0, material: concrete, kind: :blast)

    assert_operator blast, :>, impact, "concrete should yield to a blast sooner than a shove"
  end
end
