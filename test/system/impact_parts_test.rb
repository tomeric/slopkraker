require "application_system_test_case"

# The parts that only bite under a condition, and the rockets whose worth depends on how
# far they have flown. All measured through the same readout the debug overlay draws.
class ImpactPartsTest < ApplicationSystemTestCase
  teardown { page.execute_script("window.__arenaInput = null") rescue nil }

  # --- rockets wind up ----------------------------------------------------------

  test "a rocket leaves the rail slowly and picks up speed" do
    boot("buggy")

    drive(action: true)
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

    drive(action: true)
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

    drive(action: true)
    sleep 0.5
    release_action

    samples = []
    8.times { sleep 0.2; samples.concat(rockets.map { |r| r["damage"] }) }

    assert_not_empty samples
    samples.each do |damage|
      assert_operator damage, :>=, spec["minimum_damage"].floor
      assert_operator damage, :<=, spec["max_damage"].ceil
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
      visit root_path(params: { vehicle: vehicle })
      wait_for(message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
      sleep 0.8
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

    def drive(throttle: 0, brake: 0, steer: 0, slide: false, turbo: false, action: false, hop: false)
      page.execute_script(<<~JS, throttle, brake, steer, slide, turbo, action, hop)
        window.__arenaInput = { throttle: arguments[0], brake: arguments[1], steer: arguments[2],
          slide: arguments[3], turbo: arguments[4], action: arguments[5],
          slidePressed: arguments[6], pitch: 0 }
      JS
    end

    def release_action
      drive(action: false)
    end
end
