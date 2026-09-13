require "application_system_test_case"

# The edges of the world are hard and invisible. Nothing draws them, so the only way to
# know they are there is to drive into one.
class WorldBoundsTest < ApplicationSystemTestCase
  # flat is 400m across, so its wall stands at x = 200.
  EDGE = 200.0

  setup do
    visit_world("flat")
    wait_for(message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
  end

  teardown { page.execute_script("window.__arenaInput = null") }

  test "a vehicle driven at the edge is stopped by it" do
    park_facing_the_edge(10.0)
    drive_forward(2.5)

    assert_operator telemetry["x"], :<, EDGE,
      "the vehicle went straight through the edge of the world"
  end

  # Getting stopped is not enough on its own -- a vehicle that fell through the ground
  # would also never pass x = 200. It has to still be driving.
  test "the vehicle is still on its wheels after hitting the edge" do
    park_facing_the_edge(10.0)
    drive_forward(2.5)

    assert_operator telemetry["y"], :>, -5.0, "the vehicle fell out of the world"
    assert_operator telemetry["grounded"], :>, 0, "the vehicle is not on the ground"
  end

  # The wall has to be thick enough that nothing crosses it between two physics steps, and
  # a run-up from further out is the case most likely to find that out.
  test "a full run at the edge does not tunnel through it" do
    park_facing_the_edge(60.0)
    drive_forward(4.0)

    assert_operator telemetry["x"], :<, EDGE, "tunnelled through at speed"
  end

  private
    # Yaw of pi/2 points the car down +x, straight at the eastern wall.
    def park_facing_the_edge(metres_short)
      page.execute_script(
        "window.__arenaPlace = { x: #{EDGE - metres_short}, y: 2.0, z: 0, yaw: #{Math::PI / 2} }"
      )
      sleep 0.8
    end

    def drive_forward(seconds)
      page.execute_script("window.__arenaInput = { throttle: 1 }")
      sleep seconds
      page.execute_script("window.__arenaInput = null")
      sleep 0.3
    end

    def telemetry
      page.evaluate_script("window.__arena")
    end
end
