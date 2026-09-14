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

    wait_for(timeout: 20, message: "the house never left any wreckage") do
      rubble["standing"].positive?
    end

    assert_equal 0, rubble["dormant"], "a house gutted to the ground should leave all of it"
  end

  # The heaps are solid and they break, which is the difference between wreckage you have
  # to clear and a decal on the pavement.
  test "a heap is something you can hit and clear" do
    building = boot("rubble-solid")
    wreck_storey(building, 0)
    wait_for(timeout: 20, message: "the house never left any wreckage") { rubble["standing"].positive? }

    pile = a_standing_pile(building)
    assert_operator pile, :>=, 0, "no standing heap to clear"

    page.execute_script("window.__arenaDamagePiece(arguments[0], 5000, arguments[1])", pile, building)
    wait_for(timeout: 15, message: "the heap would not clear") { rubble["cleared"].positive? }
  end
end
