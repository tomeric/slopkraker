require "test_helper"

class Game::TurboBarTest < ActiveSupport::TestCase
  # Capacity 100, recharge 20/sec -> a full bar in 5 seconds, as specified.
  def build(**overrides)
    Game::TurboBar.new(**{ capacity: 100.0, recharge_rate: 20.0, recharge_delay: 0.35 }.merge(overrides))
  end

  test "starts full" do
    assert_equal 100.0, build.level
    assert_predicate build, :full?
  end

  test "recharges from empty to full in five seconds once the delay has elapsed" do
    bar = build
    assert bar.draw(100.0)
    assert_equal 0.0, bar.level

    bar.update(0.35) # delay elapses, no recharge yet
    assert_equal 0.0, bar.level

    bar.update(4.999)
    assert_operator bar.level, :<, 100.0

    bar.update(0.001)
    assert_predicate bar, :full?
  end

  test "never charges past capacity" do
    bar = build
    bar.update(60.0)
    assert_equal 100.0, bar.level
  end

  test "refuses a draw it cannot cover and leaves the level untouched" do
    bar = build
    assert bar.draw(95.0)
    assert_not bar.draw(10.0)
    assert_equal 5.0, bar.level
  end

  test "fraction reports level as a 0..1 ratio" do
    bar = build
    bar.draw(25.0)
    assert_in_delta 0.75, bar.fraction, 1e-9
  end
end
