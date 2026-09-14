require "application_system_test_case"

class RubbleTest < ApplicationSystemTestCase
  def boot(match)
    visit_world("targets", vehicle: "buggy", match: match)
    wait_for(message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
    page.evaluate_script("window.__arenaBuildingIds()[0]")
  end

  def rubble
    page.evaluate_script("window.__arenaRubble ? window.__arenaRubble() : null")
  end

  # Reserved, built and invisible. A house that has not fallen down has no wreckage, but it
  # already holds every index that wreckage will need -- the instance pools and collider
  # arrays are allocated at boot and cannot grow, so the only way a heap can appear when a
  # house comes down is for it to have been there, switched off, all along.
  test "an intact house holds its rubble dormant" do
    boot("rubble-dormant")
    state = rubble

    assert state, "the engine exposes no rubble at all"
    assert_operator state["dormant"], :>, 0, "no rubble was reserved"
    assert_equal 0, state["standing"], "an intact house is standing in its own wreckage"
  end

  def wreck_storey(building, storey, walls: 2)
    page.execute_script(<<~JS, building, storey, walls)
      const [ id, storey, count ] = [ arguments[0], arguments[1], arguments[2] ]
      const spec = window.__arenaBuildingSpec(id)
      const walls = spec.surfaces.filter(s => s.kind === "wall" && s.storey === storey)
      for (const s of walls.slice(0, count)) {
        for (let i = s.off; i < s.off + s.cols * s.rows; i++) window.__arenaDamagePiece(i, 5000, id)
      }
    JS
  end

  # An IIFE because evaluate_script wraps its body as a single expression, so a bare
  # `const` is a syntax error there. execute_script is the one that takes statements.
  # Heaps now arrive as the slabs carrying them land, so "some wreckage exists" and "the
  # wreckage is all there" are a second and a half apart. Anything asserting about the
  # finished site has to wait for the dust rather than for the first heap.
  def wait_for_the_dust_to_settle(message: "the site never settled")
    wait_for(timeout: 25, message: message) do
      page.evaluate_script("window.__arenaFalling()").zero? && rubble["dormant"].zero?
    end
  end

  def a_standing_pile(building)
    page.evaluate_script(<<~JS, building)
      (function (id) {
        const s = window.__arenaBuildingSpec(id).surfaces.find(x => x.kind === "rubble")
        for (let i = s.off; i < s.off + s.cols * s.rows; i++) {
          if (window.__arenaPieceState(i, id).standing) return i
        }
        return -1
      })(arguments[0])
    JS
  end

  test "a collapsed house leaves heaps standing on its footprint" do
    building = boot("rubble-appears")
    wreck_storey(building, 0)

    wait_for_the_dust_to_settle(message: "the house never left any wreckage")

    assert_operator rubble["standing"], :>, 0, "the house left nothing behind"
    assert_equal 0, rubble["dormant"], "a house gutted to the ground should leave all of it"
  end

  # The heaps are solid and they break, which is the difference between wreckage you have
  # to clear and a decal on the pavement.
  test "a heap is something you can hit and clear" do
    building = boot("rubble-solid")
    wreck_storey(building, 0)
    wait_for_the_dust_to_settle(message: "the house never left any wreckage")

    pile = a_standing_pile(building)
    assert_operator pile, :>=, 0, "no standing heap to clear"

    page.execute_script("window.__arenaDamagePiece(arguments[0], 5000, arguments[1])", pile, building)
    wait_for(timeout: 15, message: "the heap would not clear") { rubble["cleared"].positive? }
  end

  # The requirement in one assertion: a heap you cleared is still cleared tomorrow.
  # Dropping the registry is what makes it real -- the server's memory of this match is
  # gone, so anything that comes back can only have come from object_damages.
  test "a cleared heap stays cleared after the process that recorded it" do
    building = boot("rubble-persist")
    wreck_storey(building, 0)
    wait_for_the_dust_to_settle(message: "the house never left any wreckage")

    pile = a_standing_pile(building)
    assert_operator pile, :>=, 0, "no standing heap to clear"

    # Wait for the count to GROW, not merely to be positive: bringing the house down
    # already reported eighty-odd hits, so "positive" is true before the heap is touched,
    # and flushing on that signal writes the rows a beat before the clearing reaches them.
    before = page.evaluate_script("window.__arenaReported()")
    page.execute_script("window.__arenaDamagePiece(arguments[0], 5000, arguments[1])", pile, building)
    wait_for(timeout: 15, message: "the clearing never reached the server") do
      page.evaluate_script("window.__arenaReported()") > before
    end

    Game::Damage::Registry.flush_all!
    Game::Damage::Registry.reset!
    boot("rubble-persist")

    wait_for_the_dust_to_settle(message: "the wreckage never came back")
    refute page.evaluate_script("window.__arenaPieceState(arguments[0], arguments[1]).standing", pile, building),
           "a heap that had been cleared was back on the street"
  end

  # The requirement that started this. Two Capybara sessions and not two tabs: one browser
  # is one player, because player_id comes from the session cookie, so two tabs would share
  # it and discard each other's traffic as their own echo.
  #
  # Compares the heaps' TRANSFORMS and not merely which indices exist. Identical indices in
  # different positions would look exactly like this feature working and would not be.
  test "two players see the same heaps in the same places" do
    seen = {}

    %w[one two].each_with_index do |session, index|
      Capybara.using_session(session) do
        building = boot("rubble-agreement")
        wreck_storey(building, 0) if index.zero?

        # Compared once both sites have finished arriving. The first player reveals heaps
        # as its own slabs land; the second joins afterwards and is told what is already
        # down. They converge on the same set and only the local timing differs, which is
        # the whole reason the count is derived rather than sent.
        wait_for_the_dust_to_settle(message: "#{session} never saw any wreckage")

        seen[session] = page.evaluate_script(<<~JS, building)
          (function (id) {
            const s = window.__arenaBuildingSpec(id).surfaces.find(x => x.kind === "rubble")
            const out = []
            for (let i = s.off; i < s.off + s.cols * s.rows; i++) {
              if (!window.__arenaPieceState(i, id).standing) continue
              const m = window.__arenaPieceMatrix(i, id)
              out.push([ i ].concat(m.map(v => Math.round(v * 1000) / 1000)))
            }
            return out
          })(arguments[0])
        JS
      end
    end

    assert_operator seen["one"].length, :>, 0, "nobody saw any wreckage"
    assert_equal seen["one"], seen["two"], "the two players are looking at different rubble"
  end

  # Wreckage arrives by falling on the ground, not by being there already. The heaps used
  # to exist a second and a half before the walls did, so the wall sections fell THROUGH
  # the rubble they were supposedly becoming.
  #
  # Sampled from inside the frame loop rather than polled from here, because the whole
  # claim is about a window that is over in about 1.6 seconds.
  test "no heap is on the ground before the pieces that make it" do
    building = boot("rubble-timing")

    page.execute_script(<<~JS)
      window.__peak = { falling: 0, heapsThen: 0 }
      window.__settled = null
      ;(function sample() {
        const f = window.__arenaFalling()
        const h = window.__arenaRubble().standing
        if (f > window.__peak.falling) window.__peak = { falling: f, heapsThen: h }
        if (window.__peak.falling > 0 && f === 0 && window.__settled === null) window.__settled = h
        requestAnimationFrame(sample)
      })()
    JS

    wreck_storey(building, 0)
    wait_for(timeout: 25, message: "the house never came down") do
      page.evaluate_script("window.__settled")
    end

    peak = page.evaluate_script("window.__peak")
    settled = page.evaluate_script("window.__settled")

    assert_operator peak["falling"], :>, 0, "nothing ever fell, so this proves nothing"
    assert_equal 0, peak["heapsThen"],
                 "#{peak["heapsThen"]} heaps were already down while #{peak["falling"]} pieces were still in the air"
    assert_operator settled, :>, 0, "the pieces landed and left nothing behind"
  end

  # Two numbers that have both been quietly wrong already, and neither was visible in a
  # screenshot: a lump flattened on a horizontal axis grew vertical spikes, and a lift
  # applied along the grid's own normal -- which points DOWN -- floated every heap instead
  # of settling it. Both looked almost right.
  #
  # So: heaps cover the ground the house stood on, and every one of them stands proud of it.
  test "the wreckage covers the footprint and stands proud of it" do
    building = boot("rubble-shape")
    wreck_storey(building, 0)
    wait_for_the_dust_to_settle

    measured = page.evaluate_script(<<~JS, building)
      (function (id) {
        const spec = window.__arenaBuildingSpec(id)
        const r = spec.surfaces.find(x => x.kind === "rubble")
        let area = 0, lowest = 1
        for (let i = r.off; i < r.off + r.cols * r.rows; i++) {
          if (!window.__arenaPieceState(i, id).standing) continue
          const m = window.__arenaPieceMatrix(i, id)
          const ex = Math.hypot(m[0], m[1], m[2])
          const ey = Math.hypot(m[4], m[5], m[6])
          const ez = Math.hypot(m[8], m[9], m[10])
          area += ex * ey
          lowest = Math.min(lowest, (m[13] + ez / 2) / ez)
        }
        return { area: area, proud: lowest }
      })(arguments[0])
    JS

    assert_operator measured["area"], :>, 180.0,
                    "the wreckage covers #{measured["area"].round} m2 of a 180 m2 footprint"
    assert_operator measured["proud"], :>, 0.35,
                    "a heap stood only #{(measured["proud"] * 100).round}% out of the ground"
    assert_operator measured["proud"], :<=, 1.0,
                    "a heap is floating above the ground rather than settled into it"
  end
end
