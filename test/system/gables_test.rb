require "application_system_test_case"

# A gable end is a stair of whole cells -- those are the indices -- and the client fills
# the tooth above every column with a box and a wedge in the gable's material, so the wall
# meets the roof. The caps are drawing: they come and go with the cell they stand on.
class GablesTest < ApplicationSystemTestCase
  def boot
    visit_world("targets", match: "gables")
    wait_for(message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
    page.evaluate_script("window.__arenaBuildingIds()[0]")
  end

  def caps(building) = page.evaluate_script("window.__arenaGableCaps(arguments[0])", building)

  # The targets house has two gable ends of 12 columns each. Twelve is even, so the apex
  # falls on the seam between columns 5 and 6 and no column straddles it: every column
  # gets exactly one wedge, and the ones whose topmost kept cell stops short of the lower
  # of the roof line's two heights get a box under that wedge as well.
  test "every gable column is capped up to the roof line" do
    building = boot
    readout = caps(building)

    assert_equal 24, readout["columns"], "twelve columns per gable end, two ends"
    assert_operator readout["wedges"], :>=, 24, "at least one wedge per column"
    assert_operator readout["boxes"], :>, 0, "some columns need a box under their wedge"
    assert_equal readout["boxes"] + readout["wedges"], readout["shown"], "everything is showing on an intact house"
  end

  # Break the top standing cell of one gable column: its caps go; restore it: they return.
  test "a cap goes with the cell it stands on and comes back with it" do
    building = boot
    before = caps(building)["shown"]
    top = page.evaluate_script(<<~JS, building)
      (() => {
        const spec = window.__arenaBuildingSpec(arguments[0])
        const gable = spec.surfaces.find(s => s.kind === "gable")
        // The middle column's topmost non-void cell.
        const col = Math.floor(gable.cols / 2) - 1
        for (let row = gable.rows - 1; row >= 0; row -= 1) {
          const index = gable.off + row * gable.cols + col
          if (window.__arenaPieceState(index, arguments[0]).material !== "void") return index
        }
        return null
      })()
    JS
    assert top, "no standing cell in the column"

    page.execute_script("window.__arenaBreak(arguments[0], arguments[1])", top, building)
    after_break = caps(building)["shown"]
    assert_operator after_break, :<, before, "breaking the top cell hid nothing"

    page.execute_script("window.__arenaRestore(arguments[0], arguments[1])", top, building)
    assert_equal before, caps(building)["shown"], "restoring the cell did not bring its caps back"
  end

  # One new pool per gable material, never one per building or per column.
  test "the caps cost one draw call for the wedge pool" do
    boot
    page.driver.browser.action.key_down("g").key_up("g").perform
    wait_for(message: "debug view never hid") { page.evaluate_script("window.__arenaDebugVisible") == false }
    sleep 0.3
    assert_operator page.evaluate_script("window.__arenaDraws()"), :<, 45
  end
end
