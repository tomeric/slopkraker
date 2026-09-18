require "application_system_test_case"

# A terrace falls one dwelling at a time. The spike measured the alternative: with the row
# as the unit, gutting one house left 69% of the row's support and nothing fell.
class BaysTest < ApplicationSystemTestCase
  def boot(match, spawn: nil)
    visit_world("geleen", vehicle: "buggy", match: match, spawn: spawn)
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
      window.__church = () => window.__arenaBuildingIds().find(i => window.__arenaBuildingSpec(i).category === "church")
      // Which bay is the nave and which the tower is WORKED OUT, not assumed. The importer
      // sorts a church's parts by area, so "the nave is bay 0" happens to hold and is not
      // what this test is about: the nave is the bay with the most ground-storey wall in
      // it, and the tower the bay that reaches highest.
      window.__part = (id, which) => {
        const per = new Map()
        for (const s of window.__arenaBuildingSpec(id).surfaces) {
          if (s.kind === "rubble" || s.between) continue
          const bay = s.bay ?? 0
          const at = per.get(bay) || { ground: 0, top: -1 }
          if (s.kind === "wall" && s.storey === 0) at.ground += s.cols * s.rows
          at.top = Math.max(at.top, s.storey)
          per.set(bay, at)
        }
        const by = which === "nave" ? (a, b) => b[1].ground - a[1].ground : (a, b) => b[1].top - a[1].top
        return [ ...per.entries() ].sort(by)[0][0]
      }
      window.__standing = (id, bay) => {
        let n = 0
        for (const s of window.__arenaBuildingSpec(id).surfaces)
          if ((s.bay ?? 0) === bay && !s.between && s.kind !== "rubble")
            for (let i = s.off; i < s.off + s.cols * s.rows; i++) if (window.__arenaPieceState(i, id).standing) n++
        return n
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

  # The scenario the whole church path exists for, measured on the spike as the reason a
  # church cannot be one unit: taking the whole ground storey out of the Sint-Marcellinus
  # nave left 65% of the church's support standing, because the tower and the chapels hold
  # their own ground up and share its "storey 0". A church is a row of no dwellings and one
  # bay per part, so the nave is weighed on its own -- and imported as a dwelling row it was
  # ONE bay, which has nothing to lose and nothing to leave standing.
  test "gutting the church's nave condemns the nave and leaves the tower up" do
    boot("bays-church", spawn: 1)
    id = page.evaluate_script("window.__church()")
    assert id, "no church in the world"
    nave = page.evaluate_script("window.__part(#{id}, 'nave')")
    tower = page.evaluate_script("window.__part(#{id}, 'tower')")
    refute_equal nave, tower, "the church came out as a single bay"
    before = page.evaluate_script("window.__standing(#{id}, #{tower})")
    assert_operator before, :>, 0, "the tower has nothing standing to begin with"
    assert_operator page.evaluate_script("window.__gut(#{id}, #{nave})"), :>, 0, "the nave has no ground-storey walls"

    wait_for(timeout: 30, message: "the server never condemned the nave") { page.evaluate_script("window.__arenaCollapses()").positive? }
    assert_equal({ nave.to_s => 0 }, page.evaluate_script("window.__arenaBays(#{id})"),
                 "another part of the church was condemned with the nave")
    wait_for(timeout: 90, message: "the nave never finished falling") { page.evaluate_script("window.__arenaFalling()").zero? }
    assert_equal before, page.evaluate_script("window.__standing(#{id}, #{tower})"), "the tower came down with the nave"
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
