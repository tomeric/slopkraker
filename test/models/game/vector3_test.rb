require "test_helper"

class Game::Vector3Test < ActiveSupport::TestCase
  test "serialises to a plain array in x, y, z order" do
    assert_equal [ 1.0, 2.0, 3.0 ], Game::Vector3.new(1, 2, 3).to_a
  end

  test "coerces components to floats" do
    v = Game::Vector3.new(1, 2, 3)
    assert_equal 1.0, v.x
    assert_instance_of Float, v.y
  end

  test "builds from an array" do
    assert_equal [ 4.0, 5.0, 6.0 ], Game::Vector3[[ 4, 5, 6 ]].to_a
  end

  test "value equality" do
    assert_equal Game::Vector3.new(1, 2, 3), Game::Vector3.new(1.0, 2.0, 3.0)
  end
end
