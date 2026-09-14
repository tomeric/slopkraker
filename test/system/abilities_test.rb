require "application_system_test_case"

# The action key: jump jets on the truck, rockets on the buggy. Plus the damage the
# blade, bull bar and rockets actually do.
class AbilitiesTest < ApplicationSystemTestCase
  LIFT = %w[ front_left front_right rear_left rear_right ].freeze

  # Roll authority is strong: 11_000 against ~876 kg m^2 spins the truck up to the
  # max_angular_speed cap in about a third of a second, and past the cap updateAirControl
  # stops applying torque -- so the boosters correctly fall back towards an even burn.
  # Read the mapping before that, while the roll is still being commanded.
  ROLL_SETTLE = 0.2

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

  # --- Monster truck: boosters --------------------------------------------------

  # The boosters are the readout for an attitude the driver otherwise cannot see, so what
  # matters is not that they light but WHICH light. A nozzle underneath pushes its corner
  # UP, so the side that has to rise is the side that burns -- bank left and the RIGHT
  # boosters carry it. Mirror the mapping and every one of these still lights something;
  # only the sides swap. Hence asserting corners by name.

  test "jetting with the stick centred burns all four lift boosters evenly" do
    boot("monster_truck")
    airborne_nose

    lit = boosters
    LIFT.each { assert_operator lit[_1], :>, 0.8, "#{_1} was not burning" }
    assert_in_delta lit["front_left"], lit["front_right"], 0.05, "the truck is burning lopsided"
    assert_in_delta lit["front_left"], lit["rear_left"], 0.05, "the truck is burning lopsided"
    assert_equal 0, lit["slam"], "the roof booster fired without a slam"
  end

  test "banking left burns the right boosters and darkens the left" do
    boot("monster_truck")
    airborne_nose

    drive(action: true, steer: -1)
    sleep ROLL_SETTLE

    lit = boosters
    assert_lit lit, on: %w[ front_right rear_right ], off: %w[ front_left rear_left ]
  end

  test "banking right burns the left boosters" do
    boot("monster_truck")
    airborne_nose

    drive(action: true, steer: 1)
    sleep ROLL_SETTLE

    lit = boosters
    assert_lit lit, on: %w[ front_left rear_left ], off: %w[ front_right rear_right ]
  end

  test "dropping the nose burns the rear boosters" do
    boot("monster_truck")
    airborne_nose

    drive(action: true, pitch: 1)
    sleep 0.45

    lit = boosters
    assert_lit lit, on: %w[ rear_left rear_right ], off: %w[ front_left front_right ]
  end

  test "raising the nose burns the front boosters" do
    boot("monster_truck")
    airborne_nose

    drive(action: true, pitch: -1)
    sleep 0.45

    lit = boosters
    assert_lit lit, on: %w[ front_left front_right ], off: %w[ rear_left rear_right ]
  end

  # The base gate: bias trims a burn, it must never create one.
  test "the stick lights nothing while the jets are off" do
    boot("monster_truck")
    airborne_nose

    drive(steer: 1, pitch: -1)
    sleep 0.45

    assert_equal 0, telemetry["jets"], "the jets were still burning"
    lit = boosters
    LIFT.each { assert_operator lit[_1], :<, 0.05, "#{_1} burned with the jets off" }
  end

  test "slamming fires the roof booster and cuts the lift boosters" do
    boot("monster_truck")
    jet_high

    # The thruster cannot point both ways: committing to a slam cuts the jets.
    drive(slide: true)
    wait_for(timeout: 5, message: "never committed to a slam") { telemetry["slamming"] }
    sleep 0.25

    lit = boosters
    assert telemetry["slamming"], "landed before the slam could be read"
    assert_operator lit["slam"], :>, 0.2, "the roof booster did not fire on a slam"
    LIFT.each { assert_operator lit[_1], :<, 0.1, "#{_1} burned during a slam" }
  end

  test "the roof booster ramps with how long the slam is held" do
    boot("monster_truck")
    jet_high

    drive(slide: true)
    wait_for(timeout: 5, message: "never committed to a slam") { telemetry["slamming"] }
    sleep 0.1
    early = boosters["slam"]

    assert_operator peak_slam_booster(from: early), :>, early + 0.05,
      "the roof booster sat at #{early.round(2)} instead of ramping"
  end

  # --- Buggy: rockets -----------------------------------------------------------

  test "the action key fires rockets from the buggy" do
    boot("buggy")
    before = telemetry["rocketsFired"]

    tap_action
    sleep 0.3

    assert_equal before + 1, telemetry["rocketsFired"],
      "one press should fire exactly one rocket"
  end

  # The Ruby side asserts this arithmetic directly; this proves the client agrees.
  test "a full turbo bar yields exactly ten rockets" do
    boot("buggy")

    # Twelve presses, each well clear of the cooldown, so the bar rather than the trigger
    # is what stops it. Sampled the moment the bar runs dry: the recharge delay means
    # waiting too long buys an eleventh rocket, and too little only nine.
    before = telemetry["rocketsFired"]
    tap_action_repeatedly(times: 12, every: 0.15)
    wait_for(timeout: 8, message: "bar never ran dry") { telemetry["turbo"] < 0.01 }
    fired = telemetry["rocketsFired"] - before
    stop_tapping

    assert_equal 10, fired, "a full bar should buy exactly ten rockets"
  end

  # Firing is edge-triggered now, so the cooldown governs how fast the trigger can be
  # hammered rather than how fast a held key repeats.
  # Measured across a window rather than across a single gap: press flags are read once a
  # frame, and a headless frame can run longer than the cooldown being measured, which
  # turns any one exact gap into a coin toss.
  test "the trigger cannot be hammered faster than its cooldown" do
    boot("buggy")
    before = telemetry["rocketsFired"]

    # Ten presses across 300ms. At a 100ms floor that buys four rockets at the very most.
    tap_action_repeatedly(times: 10, every: 0.03)
    sleep 0.9
    stop_tapping

    fired = telemetry["rocketsFired"] - before
    assert_operator fired, :<=, 4, "fired #{fired} rockets in 300ms; the floor allows four"
    assert_operator fired, :>=, 2, "the cooldown looks far longer than the 100ms specified"
  end

  test "a second press clear of the floor fires again" do
    boot("buggy")

    before = telemetry["rocketsFired"]
    double_tap(gap: 0.35)
    sleep 0.6

    assert_equal before + 2, telemetry["rocketsFired"]
  end

  # Twenty taps for the ten rockets a full bar buys, which is ten more than the arithmetic
  # needs. The spare ones are not sloppiness, they are the point: press flags are consumed
  # once a frame, so when the suite is under load and a frame runs longer than the 120ms
  # between taps, two taps land in one frame and one of them is simply lost. At twelve
  # taps that left the bar with charge in it, and this test failed in its SETUP -- "bar
  # never ran dry" -- while the recharge it exists to check went untested. Extra taps
  # cost nothing: a tap that finds an empty bar fires nothing, and a draw that fails does
  # not restart the recharge delay, so they cannot buy an eleventh rocket either.
  test "rockets recharge into further shots after a pause" do
    boot("buggy")
    tap_action_repeatedly(times: 20, every: 0.12)
    wait_for(timeout: 8, message: "bar never ran dry") { telemetry["turbo"] < 0.01 }
    stop_tapping
    spent = telemetry["rocketsFired"]

    sleep 5.5
    tap_action
    sleep 0.3

    assert_operator telemetry["rocketsFired"], :>, spent, "bar never recharged into more rockets"
  end

  # A rocket caught in someone else's blast goes off with it, so a burst chains instead of
  # trickling into the scenery one shot at a time.
  test "a rocket caught in a blast goes off with it" do
    boot("buggy")
    aim_at_crates

    page.execute_script(<<~JS)
      window.__chain = { firstBlastAt: null, clearedAt: null }
      window.__chainTimer = setInterval(() => {
        const a = window.__arena
        if (!a) return
        const c = window.__chain
        const now = performance.now() / 1000
        if (c.firstBlastAt === null && a.explosions > 0) c.firstBlastAt = now
        if (c.firstBlastAt !== null && c.clearedAt === null && a.rockets === 0) c.clearedAt = now
      }, 5)
    JS

    tap_action_repeatedly(times: 4, every: 0.1)
    sleep 3.0
    seen = page.evaluate_script("window.__chain")
    page.execute_script("clearInterval(window.__chainTimer)")
    stop_tapping

    assert seen["firstBlastAt"], "nothing ever detonated"
    assert seen["clearedAt"], "rockets were still in the air at the end"
    assert_operator seen["clearedAt"] - seen["firstBlastAt"], :<, 0.25,
      "the rest of the burst kept flying for " \
      "#{(seen["clearedAt"] - seen["firstBlastAt"]).round(2)}s after the first went off"
  end

  private
    def boot(vehicle)
      visit_world("targets", vehicle: vehicle)
      wait_for(message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
      sleep 1.0
    end

    def telemetry
      page.evaluate_script("window.__arena")
    end

    # Which corners are burning. Reported together: a mirrored mapping still lights two of
    # the four, so a bare "front_left was out" says nothing about which way round it went.
    def assert_lit(lit, on:, off:)
      readout = LIFT.map { "#{_1} #{lit[_1].round(2)}" }.join(", ")
      on.each { assert_operator lit[_1], :>, 0.8, "#{_1} should be burning -- #{readout}" }
      off.each { assert_operator lit[_1], :<, 0.2, "#{_1} should be out -- #{readout}" }
    end

    # Booster intensity by nozzle name, 0..1.
    def boosters
      telemetry["boosters"].to_h { [ _1["name"], _1["intensity"] ] }
    end

    def nose_height
      telemetry["forward"][1]
    end

    # Jets up and holds there a while. A slam started just above the floor is over before
    # anything can be read off it.
    def jet_high(seconds: 1.4)
      drive(action: true)
      wait_for(timeout: 6, message: "never left the ground") { telemetry["grounded"] == 0 }
      sleep seconds
    end

    # The strongest reading the roof booster reaches before the truck lands. A slam ends on
    # touchdown, so sleeping through it and taking one reading measures the decay instead.
    def peak_slam_booster(from:, timeout: 5)
      peak = from
      deadline = Time.now + timeout
      while telemetry["slamming"] && Time.now < deadline
        peak = [ peak, boosters["slam"] ].max
        sleep 0.05
      end
      peak
    end

    # Get airborne on the jets and settle, then report the level nose attitude.
    def airborne_nose
      drive(action: true)
      wait_for(timeout: 6, message: "never left the ground") { telemetry["grounded"] == 0 }
      sleep 0.3
      nose_height
    end

    def drive(throttle: 0, brake: 0, steer: 0, slide: false, turbo: false, action: false,
              action_pressed: false, pitch: 0)
      page.execute_script(<<~JS, throttle, brake, steer, slide, turbo, action, pitch, action_pressed)
        window.__arenaInput = {
          throttle: arguments[0], brake: arguments[1], steer: arguments[2],
          slide: arguments[3], turbo: arguments[4], action: arguments[5], pitch: arguments[6],
          actionPressed: arguments[7]
        }
      JS
    end

    # One press of the trigger. The input hook consumes press flags, so this really is a
    # press rather than a hold.
    def tap_action
      drive(action_pressed: true)
    end

    # Tapped from inside the page: Selenium round trips are the same order as the cooldown
    # being measured, so scripting the timing from Ruby would prove nothing.
    def tap_action_repeatedly(times:, every:)
      page.execute_script(<<~JS, times, every * 1000)
        window.__arenaInput = {
          throttle: 0, brake: 0, steer: 0, slide: false, turbo: false, action: false, pitch: 0
        }
        let left = arguments[0]
        window.__tapTimer = setInterval(() => {
          window.__arenaInput.actionPressed = true
          if (--left <= 0) clearInterval(window.__tapTimer)
        }, arguments[1])
      JS
    end

    def double_tap(gap:)
      page.execute_script(<<~JS, gap * 1000)
        window.__arenaInput = {
          throttle: 0, brake: 0, steer: 0, slide: false, turbo: false, action: false,
          pitch: 0, actionPressed: true
        }
        setTimeout(() => { window.__arenaInput.actionPressed = true }, arguments[0])
      JS
    end

    def stop_tapping
      page.execute_script("clearInterval(window.__tapTimer)") rescue nil
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
    # Lined up on the crate stack, far enough back that the rocket is up to speed when it
    # lands: damage scales with how fast it is travelling, so a point-blank shot is worth
    # barely the minimum. Crates rather than the pillar because a pillar takes more hits
    # than the blast leaves it standing for -- it is a dynamic body, and the first blast
    # knocks it out of the firing line.
    def aim_at_crates
      page.execute_script(<<~JS)
        window.__arenaPlace = { x: 0, y: 2.0, z: 10, yaw: 0 }
      JS
      sleep 0.8
    end
end
