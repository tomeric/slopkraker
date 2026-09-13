require "application_system_test_case"

# The panel is generated from the Ruby bindings, so these assert it stays in step with
# them rather than checking hand-written markup.
class ControlsOverlayTest < ApplicationSystemTestCase
  setup do
    visit_world("flat")
    wait_for(message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
  end

  teardown { page.execute_script("window.__arenaInput = null") rescue nil }

  test "renders a row for every binding Ruby declares" do
    expected = page.evaluate_script(<<~JS)
      JSON.parse(document.querySelector('[data-arena-target="spec"]').textContent).input.display.length
    JS

    assert_equal expected, all(".controls__row", visible: :all).count
  end

  test "shows the keyboard key and the gamepad button side by side" do
    assert_selector ".controls__row kbd", visible: :all

    slide = row_for("Slide (hop to drift)")
    assert_equal "LT", slide.find(".controls__pad", visible: :all).text
    assert_includes slide.find(".controls__keys", visible: :all).text, "Space"
  end

  test "names the action after what the current vehicle does with it" do
    assert row_for("Jump jets"), "monster truck should label its action"

    visit_world("flat", vehicle: "buggy")
    wait_for { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
    assert row_for("Fire rocket"), "buggy should label its action"
  end

  test "highlights a control while it is held" do
    # Explicitly neutral, then wait: a previous test in the session can leave input held.
    page.execute_script("window.__arenaInput = { throttle: 0, brake: 0, steer: 0, slide: false, turbo: false, action: false }")
    wait_for(message: "panel did not start clean") { all(".controls__row.is-active", visible: :all).empty? }

    page.execute_script("window.__arenaInput = { throttle: 1, brake: 0, steer: 0, slide: true, turbo: false, action: false }")
    sleep 0.4

    active = all(".controls__row.is-active", visible: :all).map { |row| row.find(".controls__label", visible: :all).text }
    assert_includes active, "Accelerate"
    assert_includes active, "Slide (hop to drift)"
    assert_not_includes active, "Turbo"

    page.execute_script("window.__arenaInput = { throttle: 0, brake: 0, steer: 0, slide: false, turbo: false, action: false }")
    wait_for(message: "highlight did not clear on release") do
      all(".controls__row.is-active", visible: :all).empty?
    end
    assert_empty all(".controls__row.is-active", visible: :all)
  end

  test "highlights steering in the direction actually pressed" do
    page.execute_script("window.__arenaInput = { throttle: 0, brake: 0, steer: -1, slide: false, turbo: false, action: false }")
    sleep 0.4

    active = all(".controls__row.is-active", visible: :all).map { |row| row.find(".controls__label", visible: :all).text }
    assert_includes active, "Steer left"
    assert_not_includes active, "Steer right"
  end

  test "reports whether a gamepad is connected" do
    # Be explicit: another test in this file may have left an override on the page.
    page.execute_script("navigator.getGamepads = () => []")
    wait_for(message: "badge never cleared") do
      find(".controls__pad-badge", visible: :all).text == "no pad"
    end

    page.execute_script(<<~JS)
      navigator.getGamepads = () => [{
        id: "fake", index: 0, connected: true, mapping: "standard",
        axes: [0, 0, 0, 0],
        buttons: Array.from({ length: 17 }, () => ({ pressed: false, value: 0 })),
        timestamp: performance.now()
      }]
    JS
    wait_for(message: "badge never noticed the pad") do
      find(".controls__pad-badge", visible: :all).text == "gamepad"
    end
    assert_selector ".controls__pad-badge.is-connected", visible: :all
  ensure
    page.execute_script("navigator.getGamepads = () => []")
  end

  test "H hides and restores the panel" do
    assert_no_selector ".controls.is-hidden", visible: :all

    page.driver.browser.action.key_down("h").key_up("h").perform
    assert_selector ".controls.is-hidden", visible: :all

    page.driver.browser.action.key_down("h").key_up("h").perform
    assert_no_selector ".controls.is-hidden", visible: :all
  end

  private
    def row_for(label)
      all(".controls__row", visible: :all).find { |row| row.find(".controls__label", visible: :all).text == label }
    end
end
