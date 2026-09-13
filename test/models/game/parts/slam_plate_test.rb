require "test_helper"

class Game::Parts::SlamPlateTest < ActiveSupport::TestCase
  def plate
    Game::Parts::SlamPlate.new(
      offset: Game::Vector3.new(0, -0.42, 0),
      size: Game::Vector3.new(2.0, 0.22, 3.6),
      damage_multiplier: 4.0,
      minimum_speed: 6.0
    )
  end

  test "is armed while slamming down hard" do
    assert plate.armed?(slamming: true, fall_speed: -12.0)
  end

  test "is not armed merely falling without the thruster" do
    assert_not plate.armed?(slamming: false, fall_speed: -20.0)
  end

  test "is not armed slamming that has not built up speed yet" do
    assert_not plate.armed?(slamming: true, fall_speed: -2.0)
  end

  test "treats fall speed as a magnitude" do
    assert plate.armed?(slamming: true, fall_speed: 12.0)
  end

  test "is not armed given no state" do
    assert_not plate.armed?
  end

  test "publishes its speed threshold" do
    assert_equal 6.0, plate.to_spec[:minimum_speed]
  end
end
