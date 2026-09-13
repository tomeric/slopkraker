require "application_system_test_case"

# The debug overlay draws a wireframe hitbox over every part that can deal damage, each
# labelled with what it would do on impact right now. The numbers come from the same
# resolveDamage() the game applies, so these assert the readout against the Ruby rules
# rather than against the drawing.
class DamageOverlayTest < ApplicationSystemTestCase
  teardown { page.execute_script("window.__arenaInput = null") rescue nil }

  test "the truck shows a hitbox for its chassis and its blade" do
    boot("monster_truck")

    labels = readout.map { |e| e["label"] }
    assert_includes labels, "CHASSIS"
    assert_includes labels, "BULLDOZER BLADE"
  end

  test "the buggy shows its bull bar and launcher" do
    boot("buggy")

    labels = readout.map { |e| e["label"] }
    assert_includes labels, "BULL BAR"
    assert_includes labels, "ROCKET LAUNCHER"
  end

  test "jump jets get no hitbox because they cannot hit anything" do
    boot("monster_truck")
    assert_not_includes readout.map { |e| e["label"] }, "JUMP JETS"
  end

  test "damage reads zero at a standstill and climbs with speed" do
    boot("monster_truck")
    assert_equal 0, entry("CHASSIS")["damage"], "a parked car should threaten nothing"

    drive(throttle: 1)
    sleep 2.5

    assert_operator entry("CHASSIS")["damage"], :>, 0, "moving should do damage"
  end

  test "the blade multiplies damage over the bare chassis" do
    boot("monster_truck")
    drive(throttle: 1)
    sleep 2.5

    blade = entry("BULLDOZER BLADE")
    chassis = entry("CHASSIS")

    assert_operator blade["damage"], :>, chassis["damage"], "the blade should hit harder"
    assert_in_delta blade["bonus"], blade["damage"].to_f / chassis["damage"], 0.15
  end

  # The bull bar's bonus is conditional, and the overlay has to say so.
  test "the bull bar arms only once the buggy is drifting" do
    boot("buggy")
    drive(throttle: 1)
    sleep 2.5

    rolling = entry("BULL BAR")
    assert_not rolling["armed"], "the bull bar should be idle while rolling straight"

    commit_to_a_drift
    wait_for(timeout: 8, message: "bull bar never armed in a drift") { entry("BULL BAR")["armed"] }

    assert_operator entry("BULL BAR")["damage"], :>, rolling["damage"],
      "arming the bull bar should raise its damage"
  end

  test "the overlay hides with the debug view" do
    boot("monster_truck")
    assert page.evaluate_script("!!document.querySelector('canvas')")

    visible = page.evaluate_script("window.__arenaDebugVisible")
    assert visible, "debug view should start visible"

    page.driver.browser.action.key_down("g").key_up("g").perform
    wait_for(message: "debug view never hid") { page.evaluate_script("window.__arenaDebugVisible") == false }
  end

  private
    def boot(vehicle)
      visit_world("flat", vehicle: vehicle)
      wait_for(message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
      sleep 0.8
    end

    def readout
      wait_for(message: "damage readout never populated") do
        r = page.evaluate_script("window.__arena.damage")
        r && !r.empty? && r
      end
    end

    def entry(label)
      readout.find { |e| e["label"] == label } || flunk("no hitbox labelled #{label}")
    end

    # Up to speed, then hop into a committed right-hand drift and hold it.
    def commit_to_a_drift
      drive(throttle: 1, steer: 1, slide: true, hop: true)
      sleep 0.1
      drive(throttle: 1, steer: 1, slide: true)
    end

    def drive(throttle: 0, brake: 0, steer: 0, slide: false, turbo: false, action: false, hop: false)
      page.execute_script(<<~JS, throttle, brake, steer, slide, turbo, action, hop)
        window.__arenaInput = { throttle: arguments[0], brake: arguments[1], steer: arguments[2],
          slide: arguments[3], turbo: arguments[4], action: arguments[5],
          slidePressed: arguments[6], pitch: 0 }
      JS
    end
end
