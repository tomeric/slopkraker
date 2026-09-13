require "test_helper"

class Game::Parts::JumpJetsTest < ActiveSupport::TestCase
  def jets
    Game::Parts::JumpJets.new(
      offset: Game::Vector3.new(0, 0.2, -0.9),
      size: Game::Vector3.new(0.4, 0.4, 0.6),
      thrust: 26_000.0,
      drain_rate: 40.0
    )
  end

  def full_bar
    Game::TurboBar.new(capacity: 100.0, recharge_rate: 20.0, recharge_delay: 0.35)
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
end
