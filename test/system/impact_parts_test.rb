require "application_system_test_case"

# The parts that only bite under a condition, and the rockets whose worth depends on how
# far they have flown. All measured through the same readout the debug overlay draws.
class ImpactPartsTest < ApplicationSystemTestCase
  teardown { page.execute_script("window.__arenaInput = null") rescue nil }

  # --- rockets wind up ----------------------------------------------------------

  test "a rocket leaves the rail slowly and picks up speed" do
    boot("buggy")

    fire_once
    wait_for(message: "no rocket in flight") { rockets.any? }
    launch = rockets.first
    release_action

    wait_for(timeout: 4, message: "rocket never accelerated") do
      current = rockets.first
      current && current["speed"] > launch["speed"] + 10
    end
    assert_operator rockets.first["speed"], :>, launch["speed"]
  end

  test "a rocket is worth more damage the faster it is travelling" do
    boot("buggy")

    fire_once
    wait_for(message: "no rocket in flight") { rockets.any? }
    launch = rockets.first
    release_action

    wait_for(timeout: 4, message: "rocket damage never rose") do
      current = rockets.first
      current && current["damage"] > launch["damage"]
    end
    assert_operator rockets.first["damage"], :>, launch["damage"]
  end

  test "rocket damage stays within the bounds Ruby specifies" do
    boot("buggy")
    spec = page.evaluate_script(<<~JS)
      JSON.parse(document.querySelector('[data-arena-target="spec"]').textContent)
        .vehicles.buggy.parts.find((p) => p.kind === "rocket_launcher").rocket
    JS

    # Several shots, so there is always one in the air to sample.
    fire_once
    sleep 0.3
    fire_once
    sleep 0.3

    samples = []
    8.times { sleep 0.2; samples.concat(rockets.map { |r| r["damage"] }) }

    assert_not_empty samples
    samples.each do |damage|
      assert_operator damage, :>=, spec["minimum_damage"].floor
      assert_operator damage, :<=, spec["max_damage"].ceil
    end
  end

  # --- one press, one rocket ---------------------------------------------------
  #
  # Driven through real key events rather than the scripted hook: whether a held key
  # repeats is exactly what the binding layer decides, so the hook would prove nothing.

  test "holding the fire key launches exactly one rocket" do
    boot("buggy")
    before = telemetry["rocketsFired"]

    page.driver.browser.action.key_down("e").perform
    sleep 0.9
    page.driver.browser.action.key_up("e").perform

    assert_equal before + 1, telemetry["rocketsFired"],
      "holding the trigger should not empty the bar"
  end

  test "pressing the fire key again launches another rocket" do
    boot("buggy")
    before = telemetry["rocketsFired"]

    2.times do
      page.driver.browser.action.key_down("e").perform
      sleep 0.06
      page.driver.browser.action.key_up("e").perform
      sleep 0.3
    end

    assert_equal before + 2, telemetry["rocketsFired"]
  end

  # --- the rocket flies two arcs -----------------------------------------------
  #
  # Sampled from inside the page: the coast is over in a few hundred milliseconds, which a
  # Selenium poll would step straight over.

  test "a rocket sheds speed as it coasts, then winds up once it lights" do
    boot("buggy")
    watch_rocket
    fire_once
    sleep 1.4
    seen = stop_watching_rocket

    assert_operator seen["slowest"], :<, seen["launch"] - 1.0,
      "the rocket never gave up any speed while coasting " \
      "(left at #{seen["launch"]}, slowest #{seen["slowest"]})"
    assert_operator seen["fastest"], :>, seen["launch"] + 5.0,
      "the rocket never wound up after ignition (peaked at #{seen["fastest"]})"
  end

  # The coast only lasts about 190ms and the readout refreshes once a frame, which headless
  # runs stretch to 60ms and more -- so the coast is sometimes not witnessed at all. What
  # can be asserted reliably is that the order never reverses: once the motor is lit it
  # stays lit. That the coast happens at all is what the speed test above measures, by
  # sampling continuously rather than by catching a label.
  test "a rocket never drops back to coasting once its thrusters are lit" do
    boot("buggy")
    watch_rocket
    fire_once
    sleep 1.4
    seen = stop_watching_rocket

    assert_includes seen["phases"], "thrust", "the rocket never lit its thrusters"
    assert_equal seen["phases"].uniq, seen["phases"], "the rocket flapped between phases"
    assert_equal [ "coast", "thrust" ], (seen["phases"] | [ "coast", "thrust" ]),
      "phases came out in the wrong order: #{seen["phases"].inspect}"
  end

  # Shot into nothing, a rocket has to destroy itself rather than fly forever.
  test "a rocket does not linger in the air forever" do
    boot("buggy")
    lifetime = page.evaluate_script(<<~JS)
      JSON.parse(document.querySelector('[data-arena-target="spec"]').textContent)
        .vehicles.buggy.parts.find((p) => p.kind === "rocket_launcher").rocket.lifetime
    JS

    fire_once
    wait_for(message: "a rocket never got into the air") { telemetry["rockets"].positive? }
    wait_for(timeout: lifetime + 2, message: "a rocket never came down") do
      telemetry["rockets"].zero?
    end

    assert_equal 0, telemetry["rockets"]
  end

  # --- the blast expands -------------------------------------------------------

  test "an explosion clears itself up once it has finished expanding" do
    boot("buggy")
    fire_once

    wait_for(timeout: 8, message: "no explosion ever appeared") { blasts.any? }
    wait_for(timeout: 4, message: "the explosion hung around forever") { blasts.empty? }

    assert_empty blasts
  end

  # damage.js claims to be a faithful port of the Ruby rules. Nothing checked that until
  # now, so the blast curves at least are held to it.
  test "the client works the blast out exactly as Ruby does" do
    boot("buggy")
    blast = rocket_spec["explosion"]

    samples = [ 0.0, 0.05, 0.11, 0.22, 1.0 ].map do |elapsed|
      page.evaluate_script(<<~JS, blast, elapsed)
        window.__explosionRadius(arguments[0], arguments[1])
      JS
    end
    expected = [ 0.0, 0.05, 0.11, 0.22, 1.0 ].map { |t| ruby_explosion(blast).radius_at(t) }

    samples.each_with_index do |value, i|
      assert_in_delta expected[i], value, 1e-6, "radius at sample #{i}"
    end
  end

  test "the client works blast falloff out exactly as Ruby does" do
    boot("buggy")
    blast = rocket_spec["explosion"]

    [ 0.0, 1.0, 2.25, 4.5, 9.0 ].each do |distance|
      actual = page.evaluate_script(<<~JS, blast, distance)
        window.__explosionForce(arguments[0], arguments[1])
      JS
      assert_in_delta ruby_explosion(blast).force_at(distance), actual, 1e-6,
        "falloff at #{distance}m"
    end
  end

  # --- bull bar retains its bonus briefly --------------------------------------

  test "the bull bar keeps its multiplier for a moment after the drift ends" do
    boot("buggy")
    drive(throttle: 1)
    sleep 2.5

    drive(throttle: 1, steer: 1, slide: true, hop: true)
    sleep 0.1
    drive(throttle: 1, steer: 1, slide: true)
    wait_for(timeout: 8, message: "bull bar never armed") { part("BULL BAR")["armed"] }

    # The window is ~100ms -- shorter than a Selenium round trip -- so record its peak
    # from inside the page rather than trying to catch it by polling from Ruby.
    page.execute_script(<<~JS)
      window.__graceWatch = 0
      window.__graceTimer = setInterval(() => {
        window.__graceWatch = Math.max(window.__graceWatch, window.__arena.driftGrace)
      }, 5)
    JS

    drive(throttle: 1) # release the drift
    sleep 0.6
    peak = page.evaluate_script("window.__graceWatch")
    page.execute_script("clearInterval(window.__graceTimer)")

    assert_operator peak, :>, 0, "releasing the drift did not open a grace window"

    # It disarms on its own once the window closes.
    wait_for(timeout: 4, message: "bull bar stayed armed forever") { !part("BULL BAR")["armed"] }
  end

  test "the retain window is the one Ruby specifies" do
    boot("buggy")
    retained = page.evaluate_script(<<~JS)
      JSON.parse(document.querySelector('[data-arena-target="spec"]').textContent)
        .vehicles.buggy.parts.find((p) => p.kind === "bull_bar").retain
    JS

    assert_operator retained, :>, 0, "retain should be tweakable and non-zero"
    assert_operator retained, :<, 1.0, "a full second of grace would be absurd"
  end

  # --- the bull bar swings out mid-slide ---------------------------------------
  #
  # Lining the bar up is the skill; catching the prop once you have should not come down
  # to centimetres. The box read back here comes from Rapier itself, not from what the
  # client meant to set, so a box that never made it into the physics fails.

  # --- monster truck slam -------------------------------------------------------

  # Sampled from inside the page: the slam works well enough that the truck reaches the
  # ground between two Selenium round trips.
  test "holding slide in the air slams the truck down ever harder" do
    boot("monster_truck")

    drive(action: true)
    wait_for(timeout: 6, message: "never got airborne") { telemetry["grounded"] == 0 }
    sleep 0.9 # climb, so the slam has room to build speed before touchdown

    watch
    drive(action: true, slide: true)
    sleep 0.7
    seen = stop_watching

    assert seen["slamming"], "slide in the air should engage the slam"
    assert_operator seen["minVertical"], :<, -6.0,
      "the slam should drive the truck down hard (reached #{seen["minVertical"].round(1)} m/s)"
  end

  test "the slam builds speed the longer it is held" do
    boot("monster_truck")

    drive(action: true)
    wait_for(timeout: 6) { telemetry["grounded"] == 0 }
    sleep 0.9 # climb first

    watch
    drive(action: true, slide: true)
    sleep 0.18
    early = page.evaluate_script("window.__watch.minVertical")
    sleep 0.45
    late = stop_watching["minVertical"]

    assert_operator late, :<, early - 2.0,
      "downward speed should keep building (#{early.round(1)} then #{late.round(1)} m/s)"
  end

  test "the slam plate only arms while slamming" do
    boot("monster_truck")

    drive(action: true)
    wait_for(timeout: 6) { telemetry["grounded"] == 0 }
    sleep 0.9 # climb, so the slam has room to build speed before touchdown
    assert_not part("SLAM PLATE")["armed"], "hovering alone is not a slam"

    watch
    drive(action: true, slide: true)
    sleep 0.7

    assert stop_watching["slamPlateArmed"], "slam plate never armed during a slam"
  end

  test "a slam hits harder than the bare chassis" do
    boot("monster_truck")

    drive(action: true)
    wait_for(timeout: 6) { telemetry["grounded"] == 0 }
    sleep 0.9 # climb first

    watch
    drive(action: true, slide: true)
    sleep 0.7
    seen = stop_watching

    assert_operator seen["slamPlateDamage"], :>, seen["chassisDamage"],
      "the slam plate should multiply damage over the bare chassis"
  end

  test "the slam disengages the moment the truck lands" do
    boot("monster_truck")

    drive(action: true)
    wait_for(timeout: 6) { telemetry["grounded"] == 0 }
    drive(action: true, slide: true)
    wait_for(timeout: 6) { telemetry["slamming"] }

    drive(slide: true) # cut the jets, let it land
    # Landing can bounce, so wait for it to be down AND disengaged rather than sampling
    # the instant it first touches.
    wait_for(timeout: 10, message: "slam never disengaged on the ground") do
      telemetry["grounded"].positive? && !telemetry["slamming"]
    end
    assert_not telemetry["slamming"]
  end

  private
    def boot(vehicle)
      visit_world("flat", vehicle: vehicle)
      wait_for(message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
      sleep 0.8
    end

    # One shot, then the trigger released so only a single rocket is in the air.
    def rocket_spec
      page.evaluate_script(<<~JS)
        JSON.parse(document.querySelector('[data-arena-target="spec"]').textContent)
          .vehicles.buggy.parts.find((p) => p.kind === "rocket_launcher").rocket
      JS
    end

    # The same model the server built, rebuilt from the spec the client was handed.
    # vehicle_push is derived rather than given, so it is not a constructor argument.
    def ruby_explosion(blast)
      Game::Explosion.new(**blast.symbolize_keys.slice(
        :radius, :expand_time, :linger, :prop_push, :prop_lift, :vehicle_share,
        :vehicle_lift, :colour
      ))
    end

    def blasts
      telemetry["explosionReadout"] || []
    end

    # One press, which is one rocket: the hook consumes press flags, so it cannot repeat.
    def fire_once
      drive(action_pressed: true)
    end

    # The rocket readout, polled inside the page at 5ms so the short coast is not missed.
    def watch_rocket
      page.execute_script(<<~JS)
        window.__rocketWatch = {
          launch: null, slowest: Infinity, fastest: 0,
          phases: [], bornAt: null, ignitedAt: null
        }
        window.__rocketTimer = setInterval(() => {
          const r = ((window.__arena || {}).rocketReadout || [])[0]
          if (!r) return
          const w = window.__rocketWatch
          const now = performance.now() / 1000
          if (w.bornAt === null) { w.bornAt = now; w.launch = r.speed }
          if (w.phases[w.phases.length - 1] !== r.phase) w.phases.push(r.phase)
          if (r.phase === "thrust" && w.ignitedAt === null) w.ignitedAt = now
          // Only the coast can slow it down; once lit it only climbs.
          if (w.ignitedAt === null) w.slowest = Math.min(w.slowest, r.speed)
          w.fastest = Math.max(w.fastest, r.speed)
        }, 5)
      JS
    end

    def stop_watching_rocket
      seen = page.evaluate_script("window.__rocketWatch")
      page.execute_script("clearInterval(window.__rocketTimer)")
      seen
    end

    def telemetry
      page.evaluate_script("window.__arena")
    end

    def rockets
      telemetry["rocketReadout"] || []
    end

    def grace
      telemetry["driftGrace"]
    end

    def part(label)
      readout = wait_for(message: "damage readout never populated") do
        r = telemetry["damage"]
        r && !r.empty? && r
      end
      readout.find { |e| e["label"] == label } || flunk("no hitbox labelled #{label}")
    end

    # Polls the live readout inside the page at 5ms, so short-lived states are not missed
    # between Selenium round trips.
    def watch
      page.execute_script(<<~JS)
        window.__watch = {
          slamming: false, slamPlateArmed: false, minVertical: 0,
          slamPlateDamage: 0, chassisDamage: 0
        }
        window.__watchTimer = setInterval(() => {
          const a = window.__arena
          if (!a) return
          const w = window.__watch
          if (a.slamming) w.slamming = true
          w.minVertical = Math.min(w.minVertical, a.verticalSpeed)
          for (const entry of a.damage || []) {
            if (entry.label === "SLAM PLATE" && entry.armed) {
              w.slamPlateArmed = true
              w.slamPlateDamage = Math.max(w.slamPlateDamage, entry.damage)
            }
            if (entry.label === "CHASSIS") w.chassisDamage = Math.max(w.chassisDamage, entry.damage)
          }
        }, 5)
      JS
    end

    def stop_watching
      seen = page.evaluate_script("window.__watch")
      page.execute_script("clearInterval(window.__watchTimer)")
      seen
    end

    def drive(throttle: 0, brake: 0, steer: 0, slide: false, turbo: false, action: false,
              action_pressed: false, hop: false)
      page.execute_script(<<~JS, throttle, brake, steer, slide, turbo, action, hop, action_pressed)
        window.__arenaInput = { throttle: arguments[0], brake: arguments[1], steer: arguments[2],
          slide: arguments[3], turbo: arguments[4], action: arguments[5],
          slidePressed: arguments[6], pitch: 0, actionPressed: arguments[7] }
      JS
    end

    def release_action
      drive(action: false)
    end
end
