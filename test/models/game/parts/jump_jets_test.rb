require "test_helper"

class Game::Parts::JumpJetsTest < ActiveSupport::TestCase
  def jets(**overrides)
    Game::Parts::JumpJets.new(
      offset: Game::Vector3.new(0, 0.2, -0.9),
      size: Game::Vector3.new(0.4, 0.4, 0.6),
      thrust: 26_000.0,
      drain_rate: 40.0,
      **overrides
    )
  end

  def full_bar
    Game::TurboBar.new(capacity: 100.0, recharge_rate: 20.0, recharge_delay: 0.35)
  end

  def nozzle(**overrides)
    {
      name: "front_left",
      offset: Game::Vector3.new(0.5, -0.5, 1.4),
      direction: Game::Vector3.new(0, -1, 0),
      radius: 0.15,
      flame_length: 0.5,
      group: "lift",
      roll_bias: 1.0,
      pitch_bias: -1.0
    }.merge(overrides)
  end

  test "burning returns thrust while the bar can pay" do
    assert_equal 26_000.0, jets.burn(full_bar, 1.0 / 120)
  end

  test "burning returns no thrust once the bar is dry" do
    bar = full_bar
    assert bar.draw(100.0)
    assert_equal 0.0, jets.burn(bar, 1.0 / 120)
  end

  test "a full bar buys two and a half seconds of continuous burn" do
    assert_in_delta 2.5, jets.burn_seconds(full_bar), 1e-9
  end

  test "burning drains the bar at the drain rate" do
    bar = full_bar
    jets.burn(bar, 0.5)
    assert_in_delta 80.0, bar.level, 1e-9
  end

  # --- Nozzles ------------------------------------------------------------------

  test "jets carry no nozzles unless given any" do
    assert_equal [], jets.to_spec[:nozzles]
    assert_equal({}, jets.to_spec[:flame])
  end

  test "a nozzle serialises its vectors as arrays" do
    spec = jets(nozzles: [ nozzle ]).to_spec[:nozzles].sole

    assert_equal "front_left", spec[:name]
    assert_equal [ 0.5, -0.5, 1.4 ], spec[:offset]
    assert_equal [ 0.0, -1.0, 0.0 ], spec[:direction]
    assert_equal "lift", spec[:group]
  end

  test "a nozzle serialises its scalars as floats" do
    spec = jets(nozzles: [ nozzle(radius: 1, flame_length: 2, roll_bias: 1, pitch_bias: -1) ])
             .to_spec[:nozzles].sole

    assert_equal 1.0, spec[:radius]
    assert_equal 2.0, spec[:flame_length]
    assert_equal 1.0, spec[:roll_bias]
    assert_equal(-1.0, spec[:pitch_bias])
  end

  test "the exhaust direction is normalised" do
    spec = jets(nozzles: [ nozzle(direction: Game::Vector3.new(0, -4, 0)) ]).to_spec[:nozzles].sole

    assert_equal [ 0.0, -1.0, 0.0 ], spec[:direction]
  end

  test "bias defaults to zero, for a nozzle that should not answer the stick" do
    spec = jets(nozzles: [ nozzle.except(:roll_bias, :pitch_bias) ]).to_spec[:nozzles].sole

    assert_equal 0.0, spec[:roll_bias]
    assert_equal 0.0, spec[:pitch_bias]
  end

  test "flame tuning passes through to the spec" do
    spec = jets(flame: { core_colour: "#fff", response: 18.0 }).to_spec[:flame]

    assert_equal "#fff", spec[:core_colour]
    assert_equal 18.0, spec[:response]
  end

  test "nozzles are grouped by what drives them" do
    part = jets(nozzles: [ nozzle, nozzle(name: "slam", group: "slam") ])

    assert_equal [ "front_left" ], part.lift_nozzles.map { _1[:name] }
    assert_equal [ "slam" ], part.slam_nozzles.map { _1[:name] }
  end
end
