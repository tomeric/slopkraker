require "application_system_test_case"

# When a part actually connects, its hitbox flashes and its label switches from the live
# prediction to the damage it really dealt, holding for a beat so you can read it.
class HitFeedbackTest < ApplicationSystemTestCase
  teardown { page.execute_script("window.__arenaInput = null") rescue nil }

  test "ramming a crate stack flashes the part that connected" do
    boot("monster_truck")
    aim_at_crates

    watch
    drive(throttle: 1)
    sleep 2.5
    seen = stop_watching

    assert_operator seen["hits"], :>, 0, "nothing registered a hit"
    assert_operator seen["maxHit"], :>, 0, "the flash showed no damage"
  end

  test "the flash clears on its own and returns to the live reading" do
    boot("monster_truck")
    aim_at_crates

    drive(throttle: 1)
    wait_for(timeout: 8, message: "never hit anything") { flashing.any? }

    drive(throttle: 0, brake: 1)
    hold = page.evaluate_script(<<~JS)
      JSON.parse(document.querySelector('[data-arena-target="spec"]').textContent).rules.damage_flash
    JS

    wait_for(timeout: hold + 4, message: "flash never cleared") { flashing.empty? }
    assert_empty flashing
  end

  # The correction: a hit highlights the box and its label, but the label goes on showing
  # the live prediction. What was actually dealt floats separately.
  test "the label keeps predicting while highlighted, and the dealt number floats" do
    boot("monster_truck")
    aim_at_crates
    assert_equal 0, telemetry["hitMarkers"]

    drive(throttle: 1)
    wait_for(timeout: 8, message: "never hit anything") { flashing.any? }

    assert_operator telemetry["hitMarkers"], :>, 0, "no floating damage number appeared"
    flashing.each do |entry|
      assert_operator entry["damage"], :>, 0, "#{entry["label"]} stopped predicting while highlighted"
    end
  end

  test "the hold duration is the one Ruby specifies" do
    boot("monster_truck")
    hold = page.evaluate_script(<<~JS)
      JSON.parse(document.querySelector('[data-arena-target="spec"]').textContent).rules.damage_flash
    JS

    assert_operator hold, :>, 0.5, "too brief to read"
    assert_operator hold, :<, 4.0, "a flash should not linger this long"
  end

  test "a rocket blast leaves a floating damage marker" do
    boot("buggy")
    aim_at_pillar
    assert_equal 0, telemetry["hitMarkers"]

    # One press, one rocket: the trigger is edge-triggered.
    drive(action_pressed: true)
    sleep 0.6

    wait_for(timeout: 8, message: "blast left no marker") { telemetry["hitMarkers"].positive? }
    # And it clears itself rather than accumulating forever.
    wait_for(timeout: 10, message: "markers never cleared") { telemetry["hitMarkers"].zero? }
  end

  private
    def boot(vehicle)
      visit_world("targets", vehicle: vehicle)
      wait_for(message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
      sleep 0.8
    end

    def telemetry
      page.evaluate_script("window.__arena")
    end

    def flashing
      (telemetry["damage"] || []).select { |e| e["hit"] }
    end

    # The targets world puts a crate stack at (0, 20) and a pillar at (-20, 20). Yaw 0
    # faces +z, so lining up short of them on the same axis means driving straight in.
    #
    # Ten metres, not fourteen. The monster truck covers about fifteen metres in the two
    # and a half seconds these tests drive for, so a fourteen metre run-up arrives exactly
    # as the clock runs out and misses whenever anything is a fraction slow -- which reads
    # as "the hit did not register" rather than as "the car never got there".
    def aim_at_crates
      page.execute_script("window.__arenaPlace = { x: 0, y: 2.0, z: 10, yaw: 0 }")
      sleep 0.8
    end

    def aim_at_pillar
      page.execute_script("window.__arenaPlace = { x: -20, y: 1.2, z: 10, yaw: 0 }")
      sleep 0.8
    end

    # A hit flash is shorter than a comfortable poll, so record it inside the page.
    def watch
      page.execute_script(<<~JS)
        window.__watch = { hits: 0, maxHit: 0 }
        window.__watchTimer = setInterval(() => {
          for (const entry of (window.__arena?.damage) || []) {
            if (entry.hit === null || entry.hit === undefined) continue
            window.__watch.hits += 1
            window.__watch.maxHit = Math.max(window.__watch.maxHit, entry.hit)
          }
        }, 10)
      JS
    end

    def stop_watching
      seen = page.evaluate_script("window.__watch")
      page.execute_script("clearInterval(window.__watchTimer)")
      seen
    end

    def drive(throttle: 0, brake: 0, steer: 0, slide: false, action: false, action_pressed: false)
      page.execute_script(<<~JS, throttle, brake, steer, slide, action, action_pressed)
        window.__arenaInput = { throttle: arguments[0], brake: arguments[1], steer: arguments[2],
          slide: arguments[3], turbo: false, action: arguments[4], slidePressed: false,
          pitch: 0, actionPressed: arguments[5] }
      JS
    end
end
