require "application_system_test_case"

class MuteTest < ApplicationSystemTestCase
  setup do
    visit root_path
    wait_for(message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
  end

  teardown { page.execute_script("try { localStorage.removeItem('carnavalskraker:muted') } catch (e) {}") }

  test "starts unmuted and says so" do
    assert_equal "false", find(".hud__mute", visible: :all)["aria-pressed"]
    assert_text "Sound on"
  end

  test "clicking the button mutes and unmutes" do
    find(".hud__mute").click
    assert_selector ".hud__mute[aria-pressed='true']"
    assert_text "Muted"
    assert page.evaluate_script("window.__arena.muted")

    find(".hud__mute").click
    assert_selector ".hud__mute[aria-pressed='false']"
    assert_not page.evaluate_script("window.__arena.muted")
  end

  test "muting silences the audio graph" do
    # Unlock the context first; it stays suspended until a user gesture.
    page.driver.browser.action.key_down("c").key_up("c").perform
    wait_for { page.evaluate_script("window.__arena.audio.state") == "running" }

    find(".hud__mute").click
    assert_equal 0, page.evaluate_script("window.__arenaMasterGain()")

    find(".hud__mute").click
    assert_operator page.evaluate_script("window.__arenaMasterGain()"), :>, 0
  end

  test "the M key toggles mute too" do
    page.driver.browser.action.key_down("m").key_up("m").perform
    wait_for(message: "M did not mute") { page.evaluate_script("window.__arena.muted") }
    assert_selector ".hud__mute[aria-pressed='true']"
  end

  test "the preference survives a reload" do
    find(".hud__mute").click
    assert page.evaluate_script("window.__arena.muted")

    visit root_path
    wait_for { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }

    assert page.evaluate_script("window.__arena.muted"), "mute should be remembered"
    assert_selector ".hud__mute[aria-pressed='true']"
  end

  test "switching vehicles keeps the sound muted" do
    find(".hud__mute").click
    page.driver.browser.action.key_down("v").key_up("v").perform

    wait_for(message: "vehicle never switched") { page.evaluate_script("window.__arena.vehicle") == "buggy" }
    assert page.evaluate_script("window.__arena.muted"), "a vehicle swap should not unmute"
    assert_selector ".hud__mute[aria-pressed='true']"
  end
end
