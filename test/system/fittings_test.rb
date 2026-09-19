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

  # targets has no dormers and no chimneys, so every count above is unmoved by the
  # fittings: false rule and none of it proves the rule actually fires. geleen does --
  # Rows.detail? flags dwellings for a dakkapel or a chimney from the seed -- so this is
  # the world where "no fitting on a dakkapel or a chimney" is a claim with something to
  # break it.
  test "on geleen, a dakkapel or a chimney carries no fitting of its own" do
    visit_world("geleen", quality: "low", match: "fittings-geleen")
    wait_for(timeout: 60, message: "geleen never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }

    # Every surface the generator flagged fittings: false, on the first building that has
    # any, as its [first, last] piece index range -- the readout has no per-surface index
    # list of its own, so the range is worked out here from the same `off`/`cols`/`rows`
    # the spec ships for every surface.
    target = page.evaluate_script(<<~JS)
      (() => {
        for (const id of window.__arenaBuildingIds()) {
          const spec = window.__arenaBuildingSpec(id)
          const excluded = spec.surfaces.filter((s) => s.fittings === false)
          if (excluded.length) return { id, ranges: excluded.map((s) => [ s.off, s.off + s.cols * s.rows - 1 ]) }
        }
        return null
      })()
    JS

    assert target, "no surface shipped fittings: false -- has geleen lost its dormers and chimneys?"
    indices = page.evaluate_script("window.__arenaFittingIndices(arguments[0])", target["id"])
    # The POSITIVE CONTROL. The refute below passes on an empty list, and an empty list is
    # what a renamed hook, a building that failed to build or a boot that got this far and
    # no further all return -- so the one browser check of the user's own instruction would
    # have gone green on a broken client. That building has walls and a roof, so it has
    # fittings.
    refute_empty indices, "this building carries no fitting at all -- the refute below would pass on nothing"

    hit = target["ranges"].any? { |off, last| indices.any? { |index| index.between?(off, last) } }
    refute hit, "a fitting was keyed to a piece of a dakkapel's or a chimney's own surface"
  end

  # A deck has no eaves. Before the pitch guard, a flat roof got a 12 cm bar along whichever
  # edge its grid called row 0 -- 507 of geleen's 1,529 gutter boxes -- which reads as a kerb
  # round part of a bounding box. targets is all gable, so this goes to the street, which has
  # five flat-roofed houses among its twelve.
  test "a flat roof has no gutter, and its walls keep their downpipes" do
    visit_world("street", match: "fittings-flat")
    wait_for(timeout: 40, message: "street never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }

    flat = page.evaluate_script(<<~JS)
      (() => {
        for (const id of window.__arenaBuildingIds()) {
          const spec = window.__arenaBuildingSpec(id)
          // A roof plane's v runs up the slope, so a deck's is level.
          if (spec.surfaces.some((s) => s.kind === "roof" && Math.abs(s.v[1]) < 0.02)) {
            return { id, readout: window.__arenaFittings(id) }
          }
        }
        return null
      })()
    JS

    assert flat, "the street has no flat roof to test the guard on"
    assert_equal 0, flat["readout"]["gutters"], "a deck is not an eaves"
    assert_operator flat["readout"]["downpipes"], :>, 0, "but it still drains down its own walls"
  end
end
