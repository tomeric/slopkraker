require "application_system_test_case"

class ArenaTest < ApplicationSystemTestCase
  test "the arena boots, steps physics and renders without console errors" do
    visit root_path

    assert_selector "canvas.arena__canvas", visible: :all

    wait_for(message: "the engine never reported ready") do
      page.evaluate_script("!!(window.__arena && window.__arena.ready)")
    end

    # Physics and rendering must actually advance, not merely initialise.
    wait_for(message: "physics never stepped") do
      page.evaluate_script("window.__arena.steps") > 0
    end
    wait_for(message: "nothing ever rendered") do
      page.evaluate_script("window.__arena.frames") > 0
    end

    stats = page.evaluate_script("window.__arena")
    assert_operator stats["bodies"], :>, 0, "no dynamic bodies were tracked"

    assert_empty severe_console_errors, "console reported errors"
  end

  test "the world spec reaches the client intact" do
    visit root_path

    spec = page.evaluate_script(<<~JS)
      JSON.parse(document.querySelector('[data-arena-target="spec"]').textContent)
    JS

    assert_equal %w[buggy monster_truck], spec["vehicles"].keys.sort
    assert_operator spec["arena"]["bodies"].length, :>=, 10
    assert_equal 12, spec["version"].length
  end
end
