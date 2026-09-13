require "application_system_test_case"

# The action key: jump jets on the truck, rockets on the buggy. Plus the damage the
# blade, bull bar and rockets actually do.
class AbilitiesTest < ApplicationSystemTestCase
  teardown { stop_driving }

  # --- Monster truck: jump jets -------------------------------------------------

  test "the jump jets lift the truck off the ground" do
    boot("monster_truck")
    resting = telemetry["y"]

    drive(action: true)
    sleep 1.2

    assert_operator telemetry["y"], :>, resting + 1.0, "jets did not lift the truck"
    assert_equal 0, telemetry["grounded"], "should be airborne"
    assert_operator telemetry["turbo"], :<, 0.7, "jets did not drain the turbo bar"
  end

  test "the jets stop once the turbo bar is spent" do
    boot("monster_truck")

    drive(action: true)
    # A full bar buys 2.5s of burn at 40/sec; well past that it must be dry and idle.
    wait_for(timeout: 10, message: "bar never emptied") { telemetry["turbo"] < 0.01 }
    sleep 0.5

    assert_equal 0, telemetry["jets"], "jets still burning on an empty bar"
  end

  test "steering in the air rolls the truck rather than yawing it" do
    boot("monster_truck")

    drive(action: true)
    sleep 1.0
    assert_equal 0, telemetry["grounded"], "needed to be airborne"

    upright = telemetry["upDot"]
    drive(action: true, steer: 1)
    sleep 0.9

    assert_operator telemetry["upDot"], :<, upright - 0.05,
      "air steering did not shift weight (roll) at all"
  end

  # --- Monster truck: airborne orientation -------------------------------------

  # Pitch has its own stick axis. Measured on the forward vector's Y component: nose
  # down drives it negative.
  test "pushing the stick forward drops the nose in the air" do
    boot("monster_truck")
    level = airborne_nose

    drive(action: true, pitch: 1)
    sleep 0.8

    assert_operator nose_height, :<, level - 0.15, "stick forward did not drop the nose"
  end

  test "pulling the stick back raises the nose in the air" do
    boot("monster_truck")
    level = airborne_nose

    drive(action: true, pitch: -1)
    sleep 0.8

    assert_operator nose_height, :>, level + 0.15, "stick back did not raise the nose"
  end

  # Regression: pitch used to be driven by throttle/brake, so jumping while accelerating
  # tipped the truck over with no way to stop it.
  test "throttle and brake do not tilt the car in the air" do
    boot("monster_truck")
    level = airborne_nose

    drive(action: true, throttle: 1)
    sleep 0.8
    assert_in_delta level, nose_height, 0.12, "throttle tilted the car in the air"

    drive(action: true, brake: 1)
    sleep 0.8
    assert_in_delta level, nose_height, 0.15, "brake tilted the car in the air"
  end

  # --- Buggy: rockets -----------------------------------------------------------

  test "the action key fires rockets from the buggy" do
    boot("buggy")
    assert_equal 0, telemetry["rocketsFired"]

    drive(action: true)
    sleep 0.35
    release_action

    assert_operator telemetry["rocketsFired"], :>=, 1, "no rocket was fired"
  end

  # The Ruby side asserts this arithmetic directly; this proves the client agrees.
  test "a full turbo bar yields exactly ten rockets" do
    boot("buggy")

    # Sample the moment the bar runs dry rather than after a fixed sleep: the recharge
    # delay means waiting too long buys an eleventh rocket, and too little only nine.
    drive(action: true)
    wait_for(timeout: 6, message: "bar never ran dry") { telemetry["turbo"] < 0.01 }
    fired = telemetry["rocketsFired"]
    release_action

    assert_equal 10, fired, "a full bar should buy exactly ten rockets"
  end

  test "rockets respect the hundred millisecond floor" do
    boot("buggy")

    drive(action: true)
    sleep 0.45
    fired = telemetry["rocketsFired"]
    release_action

    # 450ms can fit at most 5 shots at a 100ms cooldown.
    assert_operator fired, :<=, 5, "fired faster than the cooldown allows"
    assert_operator fired, :>=, 3, "cooldown appears far longer than specified"
  end

  test "rockets recharge into further shots after a pause" do
    boot("buggy")
    drive(action: true)
    sleep 1.6
    spent = telemetry["rocketsFired"]
    release_action

    sleep 5.5
    drive(action: true)
    sleep 0.35
    release_action

    assert_operator telemetry["rocketsFired"], :>, spent, "bar never recharged into more rockets"
  end

  test "a rocket detonates and breaks props" do
    boot("buggy")
    assert_equal 0, telemetry["broken"]

    aim_at_pillar
    drive(action: true)
    sleep 1.2 # a pillar has 260 health; one rocket does ~120 after falloff
    release_action

    wait_for(timeout: 10, message: "rocket never detonated") { telemetry["explosions"] > 0 }
    wait_for(timeout: 10, message: "explosion broke nothing") { telemetry["broken"] > 0 }
    assert_operator telemetry["debris"], :>, 0, "breaking a prop produced no debris: #{severe_console_errors.join(' | ')}"
  end

  private
    def boot(vehicle)
      visit root_path(params: { vehicle: vehicle })
      wait_for(message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
      sleep 1.0
    end

    def telemetry
      page.evaluate_script("window.__arena")
    end

    def nose_height
      telemetry["forward"][1]
    end

    # Get airborne on the jets and settle, then report the level nose attitude.
    def airborne_nose
      drive(action: true)
      wait_for(timeout: 6, message: "never left the ground") { telemetry["grounded"] == 0 }
      sleep 0.3
      nose_height
    end

    def drive(throttle: 0, brake: 0, steer: 0, slide: false, turbo: false, action: false, pitch: 0)
      page.execute_script(<<~JS, throttle, brake, steer, slide, turbo, action, pitch)
        window.__arenaInput = {
          throttle: arguments[0], brake: arguments[1], steer: arguments[2],
          slide: arguments[3], turbo: arguments[4], action: arguments[5], pitch: arguments[6]
        }
      JS
    end

    def release_action
      drive(action: false)
    end

    def stop_driving
      page.execute_script("window.__arenaInput = null")
    rescue StandardError
      nil
    end

    # Park the buggy facing pillar_0 at (-40, -10). Crates are only 1.5m tall and the
    # launcher sits above that, so the shallow arc clears them entirely -- a 5m pillar at
    # close range is what the rockets can actually hit.
    def aim_at_pillar
      page.execute_script(<<~JS)
        window.__arenaPlace = { x: -40, y: 1.2, z: -17, yaw: 0 }
      JS
      sleep 0.6
    end
end
