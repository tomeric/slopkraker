require "application_system_test_case"

# Feel is a human judgement, but "throttle accelerates it", "the handbrake breaks rear
# traction" and "flip recovery rights it" are objective and worth guarding.
#
# Most tests drive through the scripted input hook rather than synthetic key events:
# Selenium's key timing jitters enough to swamp the physics being measured. One test
# exercises the real keyboard path so the binding layer stays covered.
class DrivingTest < ApplicationSystemTestCase
  setup do
    visit root_path
    wait_for(message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
    settle
  end

  teardown { stop_driving }

  test "the vehicle settles on its wheels under gravity" do
    assert_equal 4, telemetry["grounded"], "all four wheels should reach the ground"
    assert_operator telemetry["upDot"], :>, 0.95, "should settle upright"
  end

  test "the throttle key accelerates the vehicle forward" do
    start = position

    page.driver.browser.action.key_down("w").perform
    sleep 2.0
    page.driver.browser.action.key_up("w").perform

    assert_operator telemetry["speed"], :>, 5.0, "throttle did not accelerate"
    assert_operator travelled_forward(start), :>, 5.0, "vehicle did not move forward"
  end

  test "braking from speed brings the vehicle to a stop" do
    drive(throttle: 1)
    sleep 2.5
    assert_operator telemetry["speed"], :>, 8.0

    drive(brake: 1)
    sleep 2.0
    assert_operator telemetry["speed"], :<, 2.0, "brake did not stop the vehicle"
  end

  test "brake from rest reverses the vehicle" do
    # Flat infield: spawning on a cambered, kerbed corner makes this a coin toss.
    page.execute_script("window.__arenaPlace = { x: 0, y: 2.0, z: 0, yaw: 0 }")
    sleep 1.0
    start = position

    drive(brake: 1)
    sleep 2.5

    assert_operator telemetry["speed"], :<, -1.0, "never engaged reverse"
    assert_operator travelled_forward(start), :<, -1.0, "did not travel backwards"
  end

  # Asserted against the CAMERA's right vector, not a world axis. "Right" only means
  # anything relative to what the player sees, and a world-axis assertion happily passes
  # while steering is mirrored on screen.
  test "steering right moves the vehicle to the player's right" do
    assert_operator steer_displacement(1), :>, 1.0, "steering right did not go right on screen"
  end

  test "steering left moves the vehicle to the player's left" do
    assert_operator steer_displacement(-1), :<, -1.0, "steering left did not go left on screen"
  end

  test "steering applies a wheel angle" do
    drive(throttle: 1, steer: 1)
    sleep 1.5
    assert_operator telemetry["steer"].abs, :>, 0.05, "steer angle never applied"
  end

  test "a drift is far more sideways than the same corner on grip" do
    gripping = measure_corner(slide: false)
    sliding = measure_corner(slide: true)

    assert_operator sliding, :>, gripping * 1.5,
      "drifting (#{sliding.round(2)} rad) was not decisively more sideways " \
      "than gripping (#{gripping.round(2)} rad)"
    assert_operator sliding, :>, 0.35, "drift never passed the bull bar threshold"
  end

  # The whole point of replacing the handbrake: a drift carries momentum through the
  # corner. Measured as planar speed, because a drifting car's forward-axis component
  # collapses while it is still travelling fast.
  test "a drift carries momentum through the corner" do
    drive(throttle: 1)
    sleep 3.0
    entry = telemetry["planarSpeed"]

    hop_then_hold
    sleep 1.5

    assert telemetry["drifting"], "never entered a drift"
    assert_operator telemetry["planarSpeed"], :>, entry * 0.9,
      "drifting bled momentum (#{entry.round(1)} -> #{telemetry["planarSpeed"].round(1)} m/s)"
  end

  test "the car is visibly angled into the drift" do
    drive(throttle: 1)
    sleep 3.0
    hop_then_hold
    sleep 1.2

    assert_operator telemetry["driftAngle"].abs, :>, 0.2,
      "the car slid but never looked sideways"
  end

  # The stick trims the arc around whatever the pedals set. Measured as turn rate rather
  # than radius: radius also moves with speed, which braking changes on purpose.
  test "the stick trims the drift arc in both directions" do
    wide = drift_turn_rate(steer_trim: -1, throttle: 1, brake: 0)
    tight = drift_turn_rate(steer_trim: 1, throttle: 0, brake: 1)

    assert_operator tight, :>, wide * 2.5,
      "stick trim is too weak: #{wide.round(2)} rad/s wide vs #{tight.round(2)} rad/s tight"
  end

  # The floor is what stops a held stick opening the arc out to a near-straight line. It is
  # the client honouring a number Ruby set, so it is measured against the shipped spec
  # rather than a constant here that could quietly drift out of step with it.
  test "leaning out of the corner opens the arc to the floor the spec sets" do
    slide = buggy_slide_spec
    floor = slide["min_turn_rate"] * slide["arc_floor_scale"]

    measured = drift_turn_rate(steer_trim: -1, throttle: 1, brake: 0, vehicle: "buggy")

    assert_in_delta floor, measured, 0.02,
      "expected the arc to open out to the spec floor of #{floor.round(3)} rad/s, " \
      "got #{measured.round(3)}"
  end

  # Unclamped, leaning on the stick is worth exactly (1 + steer_arc_bounds) on the turn
  # rate, so this reads back whether the stick has the authority the spec grants it.
  test "leaning into the corner tightens the arc by the trim the spec grants" do
    bounds = buggy_slide_spec["steer_arc_bounds"]

    pedals = drift_turn_rate(steer_trim: 0, throttle: 0, brake: 1, vehicle: "buggy")
    stick = drift_turn_rate(steer_trim: 1, throttle: 0, brake: 1, vehicle: "buggy")

    assert_in_delta 1 + bounds, stick / pedals, 0.05,
      "stick trim was worth #{(stick / pedals).round(2)}x the pedals, " \
      "spec grants #{(1 + bounds).round(2)}x"
  end

  # Trail braking: weight moves forward under the brakes and the nose bites, so the same
  # steering input carries the car round a tighter circle.
  test "braking while turning tightens the turn circle" do
    free = turn_radius(brake: 0)
    braked = turn_radius(brake: 1)

    assert_operator braked, :<, free * 0.85,
      "braking did not tighten the turn (#{free.round(1)}m free vs #{braked.round(1)}m braked)"
  end

  # Pedals shape the arc with the stick held neutral, so this isolates them from the
  # stick trim covered above. Measured as turn rate: radius also moves with speed, which
  # braking changes on purpose.
  test "braking mid-drift tightens the arc and throttle widens it" do
    wide = drift_turn_rate(steer_trim: 0, throttle: 1, brake: 0)
    tight = drift_turn_rate(steer_trim: 0, throttle: 0, brake: 1)

    assert_operator tight, :>, wide * 1.3,
      "braking (#{tight.round(2)} rad/s) did not tighten the arc versus throttle (#{wide.round(2)} rad/s)"
  end

  test "the hop lifts the vehicle off the ground" do
    resting = telemetry["y"]
    drive(throttle: 0, slide: true, hop: true)
    sleep 0.18

    assert_operator telemetry["y"], :>, resting + 0.15, "pressing slide did not hop"
  end

  test "a drift rotates the vehicle harder than grip alone" do
    assert_operator drift_yaw_change(slide: true).abs, :>,
                    drift_yaw_change(slide: false).abs * 1.2,
                    "drifting did not turn the car more sharply"
  end

  test "holding a drift long enough banks a boost" do
    drive(throttle: 1)
    sleep 3.0

    hop_then_hold
    wait_for(timeout: 8, message: "drift never charged a boost") { telemetry["boostCharged"] }

    before = telemetry["planarSpeed"]
    drive(throttle: 1) # release
    sleep 0.2

    assert telemetry["boosting"], "releasing a charged drift gave no boost"
    # NOTE: the flick-out already fires the car out near its speed cap, so the charged
    # mini-turbo currently has little headroom left to show in exit speed. Worth
    # revisiting when tuning -- the two mechanics overlap.
    assert_operator telemetry["planarSpeed"], :>, before * 0.9,
      "the exit should carry speed out of the corner, not scrub it"
  end

  test "a brief drift banks no boost" do
    drive(throttle: 1)
    sleep 3.0

    hop_then_hold
    sleep 0.3
    drive(throttle: 1)
    sleep 0.15

    assert_not telemetry["boosting"], "a flick of the drift button should not earn a boost"
  end

  test "turbo drains the bar and it recharges to full in five seconds" do
    assert_in_delta 1.0, telemetry["turbo"], 0.01

    drive(throttle: 1, turbo: true)
    sleep 1.0
    assert_operator telemetry["turbo"], :<, 0.85, "turbo did not drain the bar"

    drive(throttle: 1)
    sleep 5.5
    assert_in_delta 1.0, telemetry["turbo"], 0.02, "bar did not recharge to full"
  end

  test "turbo makes the vehicle accelerate harder" do
    drive(throttle: 1)
    sleep 1.5
    plain = telemetry["speed"]

    visit root_path
    wait_for { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
    settle

    drive(throttle: 1, turbo: true)
    sleep 1.5
    boosted = telemetry["speed"]

    assert_operator boosted, :>, plain, "turbo gave no extra acceleration"
  end

  test "the slide button flips an upside down vehicle back onto its wheels" do
    # Do this on flat infield ground: landing back on a cambered, kerbed corner makes
    # "settled on its wheels" a coin toss that has nothing to do with flip recovery.
    page.execute_script("window.__arenaPlace = { x: 0, y: 2.0, z: 0, yaw: 0 }")
    sleep 0.8

    flip_upside_down
    assert_operator telemetry["upDot"], :<, -0.5, "test setup failed to invert the vehicle"

    drive(slide: true)
    wait_for(timeout: 12, message: "flip recovery never righted the vehicle") do
      telemetry["upDot"] > 0.8
    end

    # It rights itself first and settles a moment later.
    wait_for(timeout: 10, message: "never settled back on its wheels") do
      telemetry["grounded"] >= 3
    end
  end

  test "switching vehicles rebuilds the car" do
    assert_equal "monster_truck", telemetry["vehicle"]

    page.driver.browser.action.key_down("v").perform
    page.driver.browser.action.key_up("v").perform

    wait_for(message: "vehicle never switched") { telemetry["vehicle"] == "buggy" }
    wait_for(message: "buggy never settled") { telemetry["grounded"] == 4 }
  end

  private
    def buggy_slide_spec
      page.evaluate_script(<<~JS)
        JSON.parse(document.querySelector('[data-arena-target="spec"]').textContent)
          .vehicles.buggy.slide
      JS
    end

    def telemetry
      page.evaluate_script("window.__arena")
    end

    def settle
      sleep 1.0
    end

    def position
      t = telemetry
      [ t["x"], t["y"], t["z"] ]
    end

    # Distance travelled along the car's own heading. Spawns follow the track, so a world
    # axis says nothing about whether the car went forwards.
    def travelled_forward(start)
      t = telemetry
      moved = [ t["x"] - start[0], t["y"] - start[1], t["z"] - start[2] ]
      moved.zip(t["forward"]).sum { |a, b| a * b }
    end

    # Tightest radius the car sustains while still actually travelling. Radius is only
    # meaningful above walking pace, hence the speed floor.
    def turn_radius(brake:)
      visit root_path
      wait_for { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
      settle

      drive(throttle: 1)
      sleep 2.5
      drive(throttle: brake.zero? ? 1 : 0, brake: brake, steer: 1)

      samples = []
      10.times do
        sleep 0.15
        t = telemetry
        yaw = t["yawRate"].abs
        samples << t["planarSpeed"] / yaw if yaw > 0.05 && t["planarSpeed"] > 3.0
      end

      flunk "never sustained a measurable turn" if samples.empty?
      samples.min
    end

    # `steer_trim` is relative to the drift direction: +1 leans into the corner. The arc
    # is tuned per vehicle, so which one is driving matters: root_path alone boots the
    # monster truck.
    def drift_turn_rate(steer_trim:, throttle:, brake:, vehicle: nil)
      visit(vehicle ? root_path(params: { vehicle: vehicle }) : root_path)
      wait_for { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
      settle

      drive(throttle: 1)
      sleep 2.5
      hop_then_hold
      sleep 0.7
      drive(throttle: throttle, brake: brake, steer: steer_trim, slide: true)
      sleep 0.8

      telemetry["driftTurnRate"]
    end

    # How far the vehicle moved along the camera's own right vector.
    def steer_displacement(direction)
      drive(throttle: 1)
      sleep 1.5

      before = telemetry
      right = before["camRight"]
      start = [ before["x"], before["y"], before["z"] ]

      drive(throttle: 1, steer: direction)
      sleep 1.5

      after = telemetry
      moved = [ after["x"] - start[0], after["y"] - start[1], after["z"] - start[2] ]
      moved.zip(right).sum { |a, b| a * b }
    end

    # Returns how far the vehicle moved along the camera's right vector.
    def steer_displacement(direction)
      drive(throttle: 1)
      sleep 1.5

      before = telemetry
      right = before["camRight"]
      start = [ before["x"], before["y"], before["z"] ]

      drive(throttle: 1, steer: direction)
      sleep 1.5

      after = telemetry
      moved = [ after["x"] - start[0], after["y"] - start[1], after["z"] - start[2] ]
      moved.zip(right).sum { |a, b| a * b }
    end

    def drive(throttle: 0, brake: 0, steer: 0, slide: false, turbo: false, action: false, hop: false, pitch: 0)
      page.execute_script(<<~JS, throttle, brake, steer, slide, turbo, action, hop, pitch)
        window.__arenaInput = {
          throttle: arguments[0], brake: arguments[1], steer: arguments[2],
          slide: arguments[3], turbo: arguments[4], action: arguments[5],
          slidePressed: arguments[6], pitch: arguments[7]
        }
      JS
    end

    # The hop fires on a press edge, so it has to be pulsed rather than held.
    def hop_then_hold(throttle: 1, steer: 1)
      drive(throttle: throttle, steer: steer, slide: true, hop: true)
      sleep 0.08
      drive(throttle: throttle, steer: steer, slide: true)
    end

    def stop_driving
      page.execute_script("window.__arenaInput = null")
    rescue StandardError
      nil
    end

    # Fresh page each time so both corners start from identical state.
    def measure_corner(slide:)
      visit root_path
      wait_for { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
      settle

      drive(throttle: 1)
      sleep 3.0
      slide ? hop_then_hold : drive(throttle: 1, steer: 1)

      peak = 0.0
      14.times do
        sleep 0.1
        peak = [ peak, telemetry["slipAngle"].abs ].max
      end
      peak
    end

    def drift_yaw_change(slide:)
      visit root_path
      wait_for { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
      settle

      drive(throttle: 1)
      sleep 3.0
      start = telemetry["yaw"]

      slide ? hop_then_hold : drive(throttle: 1, steer: 1)
      sleep 1.5

      delta = telemetry["yaw"] - start
      # unwrap across the +/-pi seam
      delta += 2 * Math::PI while delta < -Math::PI
      delta -= 2 * Math::PI while delta > Math::PI
      delta
    end

    def flip_upside_down
      page.execute_script(<<~JS)
        window.__arenaFlip = true
      JS
      wait_for(message: "flip hook never fired") { telemetry["upDot"] < -0.5 }
    end
end
