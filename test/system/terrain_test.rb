require "application_system_test_case"

# The ground has elevation, the car stands on it, and what it stands on is what is drawn.
class TerrainTest < ApplicationSystemTestCase
  def boot(match)
    visit_world("hills", match: match)
    wait_for(message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
  end

  def height_at(x, z)
    page.evaluate_script("window.__arenaTerrainHeight(arguments[0], arguments[1])", x, z)
  end

  def telemetry
    page.evaluate_script("window.__arena")
  end

  def drive(input, seconds)
    page.execute_script("window.__arenaInput = arguments[0]", input)
    sleep seconds
    page.execute_script("window.__arenaInput = null")
  end

  teardown { page.execute_script("window.__arenaInput = null") }

  # The wheels are raycasts on WHEEL_RAY_GROUPS, which excludes only rubble, so they should
  # find a heightfield with no change. Should is not did.
  test "the car settles on the hilltop it spawns over" do
    boot("terrain-spawn")
    assert_in_delta 7.7, height_at(0.0, 0.0), 0.05, "the hilltop is not where the function puts it"

    sleep 1.5
    t = telemetry
    assert_equal 4, t["grounded"], "all four wheels should be on the heightfield"
    clearance = t["y"] - height_at(t["x"], t["z"])
    assert_operator clearance, :>, 0.2, "the car sank into the ground"
    assert_operator clearance, :<, 2.5, "the car is floating above the ground it is drawn on"
  end

  test "the car drives down the slope on its wheels and comes to rest on it" do
    boot("terrain-drive")
    sleep 1.0
    drive({ throttle: 1 }, 2.5)
    drive({ brake: 1 }, 1.5)
    sleep 0.5

    t = telemetry
    assert_operator t["z"], :>, 10.0, "did not drive down the slope"
    ground = height_at(t["x"], t["z"])
    assert_operator ground, :<, 7.0, "should have descended from the hilltop"
    assert_operator t["grounded"], :>, 0, "the wheels lost the heightfield"
    clearance = t["y"] - ground
    assert_operator clearance, :>, 0.2, "sank into the slope"
    assert_operator clearance, :<, 2.5, "floating above the slope"
  end
end
