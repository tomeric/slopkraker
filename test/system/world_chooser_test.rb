require "application_system_test_case"

# The front door. A bare visit names no world, so rather than guessing one it offers the
# choice -- and a link with a typo in it says so instead of quietly loading somewhere else.
class WorldChooserTest < ApplicationSystemTestCase
  test "visiting without a world offers the ones there are" do
    visit root_path

    assert_selector "h1", text: "Carnavalskraker"
    assert_selector ".world__name", text: "Flat"
    assert_selector ".world__name", text: "Targets"
    assert_no_selector "canvas.arena__canvas"
  end

  test "each world says what is in it" do
    visit root_path

    assert_selector ".world", text: "3 crates"
    assert_selector ".world", text: "pillar"
  end

  test "picking a world loads it with the vehicle chosen" do
    visit root_path
    within(".world", text: "Targets") { click_link "Buggy" }

    wait_for(message: "engine never booted") do
      page.evaluate_script("!!(window.__arena && window.__arena.ready)")
    end

    assert_equal "buggy", page.evaluate_script("window.__arena.vehicle")
    assert_equal 4, page.evaluate_script("window.__arena.bodies"), "should be in Targets"
  end

  # The failure this prevents: a typo'd slug quietly loading flat ground, so a test or a
  # player measures the wrong world and the mistake never surfaces.
  test "an unknown world says so rather than loading another one" do
    visit root_path(params: { world: "nope" })

    assert_selector ".chooser__note", text: "no world called"
    assert_no_selector "canvas.arena__canvas"
  end
end
