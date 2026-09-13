require "test_helper"

class Game::Parts::BullBarTest < ActiveSupport::TestCase
  def bar
    Game::Parts::BullBar.new(
      offset: Game::Vector3.new(0, 0.4, -1.8),
      size: Game::Vector3.new(1.8, 0.3, 0.2),
      damage_multiplier: 3.0,
      minimum_slip_angle: 0.35,
      retain: 0.1
    )
  end

  test "is armed only while drifting past the angle threshold" do
    assert bar.armed?(drifting: true, slip_angle: 0.6)
  end

  test "is not armed while drifting without slip" do
    assert_not bar.armed?(drifting: true, slip_angle: 0.1)
  end

  test "is not armed while sideways but not drifting" do
    assert_not bar.armed?(drifting: false, slip_angle: 1.1)
  end

  test "treats slip angle as a magnitude so either direction counts" do
    assert bar.armed?(drifting: true, slip_angle: -0.6)
  end

  test "is not armed given no state at all" do
    assert_not bar.armed?
  end

  # The grace window is what lets a hit land just as you straighten up out of the drift.
  test "stays armed while the drift grace is still running" do
    assert bar.armed?(drifting: false, slip_angle: 0.0, drift_grace: 0.05)
  end

  test "disarms once the grace has run out" do
    assert_not bar.armed?(drifting: false, slip_angle: 0.0, drift_grace: 0.0)
  end

  test "exposes the retain window so it can be tuned" do
    assert_equal 0.1, bar.retain
    assert_equal 0.1, bar.to_spec[:retain]
  end
end
