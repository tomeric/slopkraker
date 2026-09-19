require "application_system_test_case"

# The rainwater goods: a gutter along every eaves and a downpipe at every corner. Drawing
# rather than pieces -- 120 mm of folded zinc is not worth an index -- so what the tests
# assert is that each one hangs on a cell and goes when that cell goes.
class FittingsTest < ApplicationSystemTestCase
  def boot
    visit_world("targets", match: "fittings")
    wait_for(message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
    page.evaluate_script("window.__arenaBuildingIds()[0]")
  end

  def fittings(building) = page.evaluate_script("window.__arenaFittings(arguments[0])", building)

  # The targets house has two roof planes of 16 columns and four walls of three storeys.
  test "every eaves column has a gutter and every wall end a downpipe" do
    building = boot
    readout = fittings(building)

    assert_equal 32, readout["gutters"], "one per column of each plane's bottom row"
    assert_equal 12, readout["downpipes"], "one per storey at the last column of each of the four walls"
    assert_equal 1, readout["fittingPools"], "zinc is steel's pool, and there is only the one"
    assert_equal readout["gutters"] + readout["downpipes"], readout["shownFittings"]
  end

  test "a fitting goes with the cell it hangs on and comes back with it" do
    building = boot
    before = fittings(building)["shownFittings"]
    cell = page.evaluate_script(<<~JS, building)
      (() => {
        const spec = window.__arenaBuildingSpec(arguments[0])
        const plane = spec.surfaces.find(s => s.kind === "roof")
        // The bottom row's middle column: a gutter hangs on it.
        return plane.off + Math.floor(plane.cols / 2)
      })()
    JS

    page.execute_script("window.__arenaBreak(arguments[0], arguments[1])", cell, building)
    assert_operator fittings(building)["shownFittings"], :<, before, "breaking the eaves cell hid no gutter"

    page.execute_script("window.__arenaRestore(arguments[0], arguments[1])", cell, building)
    assert_equal before, fittings(building)["shownFittings"], "restoring it brought no gutter back"
  end

  test "the fittings cost no draw call of their own" do
    boot
    page.driver.browser.action.key_down("g").key_up("g").perform
    wait_for(message: "debug view never hid") { page.evaluate_script("window.__arenaDebugVisible") == false }
    sleep 0.3
    assert_operator page.evaluate_script("window.__arenaDraws()"), :<, 45
  end
end
