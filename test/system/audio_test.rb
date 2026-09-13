require "application_system_test_case"

# Audio is procedural Web Audio -- no sample files. These assert the graph actually comes
# up and carries the voices the Ruby spec asked for; how it sounds is a human judgement.
class AudioTest < ApplicationSystemTestCase
  test "the audio graph starts on a user gesture and builds the truck's voices" do
    boot("monster_truck")

    assert_equal "none", telemetry["audio"]["state"], "context should not exist before a gesture"

    gesture
    wait_for(message: "audio context never started") { telemetry["audio"]["state"] == "running" }

    # engine + turbo + jets + skid + one-shots
    assert_equal 5, telemetry["audio"]["voices"], "monster truck voice count"
    assert telemetry["audio"]["enabled"]
  end

  test "the buggy builds a rocket voice instead of jets" do
    boot("buggy")
    gesture
    wait_for { telemetry["audio"]["state"] == "running" }

    # engine + turbo + skid + one-shots: no jets block in the buggy's spec
    assert_equal 4, telemetry["audio"]["voices"], "buggy voice count"
  end

  test "driving with audio running raises no console errors" do
    boot("monster_truck")
    gesture
    wait_for { telemetry["audio"]["state"] == "running" }

    page.execute_script("window.__arenaInput = { throttle: 1, brake: 0, steer: 0.5, slide: true, turbo: true, action: true }")
    sleep 2.5
    page.execute_script("window.__arenaInput = null")

    assert_empty severe_console_errors
  end

  private
    def boot(vehicle)
      visit root_path(params: { vehicle: vehicle })
      wait_for(message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
      sleep 0.5
    end

    def telemetry
      page.evaluate_script("window.__arena")
    end

    def gesture
      page.driver.browser.action.key_down("c").key_up("c").perform
    end
end
