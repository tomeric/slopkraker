require "application_system_test_case"

# A terrace falls one dwelling at a time. The spike measured the alternative: with the row
# as the unit, gutting one house left 69% of the row's support and nothing fell.
class BaysTest < ApplicationSystemTestCase
  def boot(match)
    visit_world("geleen", vehicle: "buggy", match: match)
    wait_for(timeout: 60, message: "geleen never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
    # `ready` is the engine having booted, not the world having run. Same milestone
    # geleen_test waits on, and for the same reason: nothing physical -- a raycast, a
    # falling slab, a contact -- has happened yet at `ready`.
    wait_for(timeout: 60, message: "the world never stepped") { page.evaluate_script("window.__arena.steps").positive? }
    page.execute_script(<<~JS)
      window.__row = () => window.__arenaBuildingIds().find(i => {
        const s = window.__arenaBuildingSpec(i)
        if (s.category !== "house") return false
        const walls = s.surfaces.filter(x => x.kind === "wall")
        // Four DWELLINGS, not four boxes. A bay is only a dwelling where a party wall
        // joins it to the one next door, and boxes carry bays too -- so a church wing
        // with four annexes answers this finder with four bays and nothing shared, and
        // gutting it would assert nothing at all about a terrace.
        const bays = new Set(walls.filter(x => !x.between).map(x => x.bay ?? 0))
        return bays.size >= 4 && walls.some(x => x.between && x.between.includes(1))
      })
      window.__gut = (id, bay) => {
        const spec = window.__arenaBuildingSpec(id)
        const walls = spec.surfaces.filter(s => s.kind === "wall" && s.storey === 0 && !s.between && (s.bay ?? 0) === bay)
        for (const s of walls) for (let i = s.off; i < s.off + s.cols * s.rows; i++) window.__arenaDamagePiece(i, 5000, id)
        return walls.length
      }
    JS
  end

  test "gutting one dwelling drops that dwelling and leaves its neighbours standing" do
    boot("bays-one")
    id = page.evaluate_script("window.__row()")
    assert id, "no row of four in the world"
    page.evaluate_script("window.__gut(#{id}, 1)")

    wait_for(timeout: 30, message: "the server never condemned the bay") { page.evaluate_script("window.__arenaCollapses()").positive? }
    assert_equal({ "1" => 0 }, page.evaluate_script("window.__arenaBays(#{id})"))
    wait_for(timeout: 60, message: "the bay never finished falling") { page.evaluate_script("window.__arenaFalling()").zero? }
    standing_bay2 = page.evaluate_script(<<~JS, id)
      (() => { const spec = window.__arenaBuildingSpec(arguments[0]); let n = 0
        for (const s of spec.surfaces.filter(s => (s.bay ?? 0) === 2 && !s.between && s.kind !== "rubble"))
          for (let i = s.off; i < s.off + s.cols * s.rows; i++) if (window.__arenaPieceState(i, arguments[0]).standing) n++
        return n })()
    JS
    assert_operator standing_bay2, :>, 0, "the neighbour came down too"
    party = page.evaluate_script("window.__arenaBuildingSpec(#{id}).surfaces.find(s => s.between && s.between.includes(1) && s.storey === 1)")
    assert party, "the row has no party wall over the gutted dwelling"
    assert page.evaluate_script("window.__arenaPieceState(#{party['off']}, #{id}).standing"), "a shared wall was felled"
    rubble = page.evaluate_script("window.__arenaRubble()")
    assert_operator rubble["standing"], :>, 0, "the fallen bay left no wreckage"
    # `__arenaRubble` counts the WHOLE world. Over forty-eight buildings "dormant beats
    # standing" is true by three orders of magnitude whatever happened here, so it asserts
    # nothing -- the number has to be nameable instead. This is a fresh match, so the only
    # wreckage standing anywhere is this collapse's; the bay came down from storey 0, which
    # leaves all of its heaps and none of anybody else's.
    assert_equal page.evaluate_script("window.__arenaPileOrder(#{id}, 1).length"), rubble["standing"],
                 "the wreckage standing is not exactly the felled bay's"
  end

  test "the client and the server reveal a bay's heaps in the same order" do
    boot("bays-order")
    id = page.evaluate_script("window.__row()")
    record = WorldObject.find(id)
    surface = record.surface_set.surfaces.last
    orders = [ 0, 1 ].map do |bay|
      order = page.evaluate_script("window.__arenaPileOrder(#{id}, #{bay})")
      # Two sides answering [] agree about nothing, and two sides answering the WHOLE
      # grid's order agree about nothing per bay: drop `bays` from the rubble surface and
      # both languages fall back to it, in step, for every bay. So the orders have to be
      # non-empty and have to differ from each other before agreeing means anything.
      refute_empty order, "bay #{bay} was given no heaps"
      assert_equal Game::Building::Rubble.pile_indices(surface, bay: bay), order,
                   "the client reveals bay #{bay} in an order the server does not gate on"
      order
    end
    refute_equal orders[0], orders[1], "both bays were handed the same heaps"
  end
end
