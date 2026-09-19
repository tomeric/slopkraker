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
    # Every one of the 24 columns gets a cap -- columns 0 and 11 have no standing cell of
    # their own and anchor to their neighbour, but still carry a real box/wedge. Every
    # column, on every gable, now that Roof.clip judges a column by its lower end: the apex
    # column used to be kept whole and capless, and is capped to a point instead. The test
    # below drives out to the street to watch that happen, since twelve columns has none.
    assert_equal readout["columns"], readout["capped"], "every column should have at least one cap"
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

  # THE RIDGE IS DRAWN, and by two wedges rather than one.
  #
  # Roof.clip keeps only what is wholly under the roof across a whole column, so the column
  # the ridge falls inside is clipped like any other -- on a nine-column gable both its ends
  # are at 8/9 of the height. A single wedge would cap it to 8/9 and stop, and
  # the gable would come to a flat notch where its point should be. Asserted on the caps
  # themselves, through the module the client draws them from: two wedges, each reaching the
  # gable's FULL height, meeting over the column's own middle. Targets cannot show this --
  # twelve columns puts the ridge on a seam -- so this one test drives out to the street.
  test "the column the ridge falls inside is capped to a point" do
    visit_world("street", match: "gables-ridge")
    wait_for(message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }

    page.execute_script(<<~JS)
      window.__gab = null
      import("game/world/gables").then(({ gableCaps }) => {
        const odd = (s) => s.kind === "gable" && s.cols % 2 === 1
        const id = window.__arenaBuildingIds().find(i => window.__arenaBuildingSpec(i).surfaces.some(odd))
        const gable = window.__arenaBuildingSpec(id).surfaces.find(odd)
        const apex = gableCaps(gable)[(gable.cols - 1) / 2]
        window.__gab = {
          id, cols: gable.cols, h: gable.h,
          // Every gable column of this building, which is what the readout counts.
          columns: window.__arenaBuildingSpec(id).surfaces.filter(s => s.kind === "gable").reduce((n, s) => n + s.cols, 0),
          tops: apex.wedges.map(w => w.y0 + w.height),
          // Each wedge's TALL corner: the unmirrored one is high on its right, the
          // mirrored one high on its left. Both should land on the ridge.
          peaks: apex.wedges.map(w => w.high > 0 ? w.x0 + w.width : w.x0),
          middle: (apex.col + 0.5) * gable.w / gable.cols
        }
      })
    JS
    wait_for(message: "the gables module never loaded") { page.evaluate_script("!!window.__gab") }
    gab = page.evaluate_script("window.__gab")

    assert_equal 2, gab["tops"].length, "the apex column should carry two wedges, not one"
    gab["tops"].each { |top| assert_in_delta gab["h"], top, 1e-6, "a wedge stops short of the ridge" }
    gab["peaks"].each { |x| assert_in_delta gab["middle"], x, 1e-6, "the two wedges do not meet over the ridge" }

    # And they are really placed, not merely computed. Every other column carries exactly
    # one wedge, so more wedges than columns is the apex column's second one -- placed, in
    # a pool, and showing. The street's houses differ in footprint, so how many columns
    # that is comes off this building's own spec rather than being written down here.
    readout = caps(gab["id"])
    assert_equal gab["columns"], readout["columns"]
    assert_operator readout["wedges"], :>, readout["columns"], "the apex column's second wedge was never placed"
    assert_equal readout["boxes"] + readout["wedges"], readout["shown"], "a cap was placed and not shown"
  end

  # One new pool per gable MATERIAL, never one per building or per column. The total draw
  # count cannot say that here -- on a one-building world "a pool per material" and "a pool
  # per building" are the same number -- so the assertion is the number of distinct
  # `#wedge` pools the caps were placed in. `street_test` is what proves the pools are
  # SHARED across buildings; this proves the targets house asks for exactly one.
  test "the caps cost one draw call for the wedge pool" do
    building = boot
    readout = caps(building)

    assert_equal 1, readout["wedgePools"],
                 "both gables are brick, so every wedge belongs in brick#wedge and nowhere else"
    assert_operator readout["wedges"], :>, readout["wedgePools"], "many wedges, one pool"

    page.driver.browser.action.key_down("g").key_up("g").perform
    wait_for(message: "debug view never hid") { page.evaluate_script("window.__arenaDebugVisible") == false }
    sleep 0.3
    assert_operator page.evaluate_script("window.__arenaDraws()"), :<, 45
  end
end
