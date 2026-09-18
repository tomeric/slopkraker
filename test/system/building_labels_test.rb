require "application_system_test_case"

# The debug overlay names every building near the car -- what it is, what it is called,
# and what it was built from -- so a building can be talked about by name rather than
# pointed at. Asserted on the words the plates carry, not on pixels.
class BuildingLabelsTest < ApplicationSystemTestCase
  test "the overlay labels a building by category, name and source id, and hides with it" do
    visit_world("targets")
    wait_for(message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }

    labels = page.evaluate_script("window.__arenaBuildingLabels()")
    house = labels.find { |label| label["name"] == "house" }
    assert house, "the house has no plate: #{labels.inspect}"
    # A hand-made building has no source records, so its category is its kind and its id
    # stands in for the ids it was built from.
    assert_equal "building", house["category"]
    assert_equal [ "##{house['id']}" ], house["ids"]

    # The spawn is twenty metres from the house, well inside range, and the overlay starts
    # on -- so its plate is showing once the first frame has been drawn.
    wait_for(message: "the plate never showed") do
      page.evaluate_script("window.__arenaBuildingLabels().some(label => label.name === 'house' && label.shown)")
    end

    # G takes the whole overlay down, plates included.
    page.driver.browser.action.key_down("g").key_up("g").perform
    wait_for(message: "the plate stayed up with the overlay off") do
      page.evaluate_script("window.__arenaBuildingLabels().every(label => !label.shown)")
    end
    assert_equal false, page.evaluate_script("window.__arenaDebugVisible")
  end
end
