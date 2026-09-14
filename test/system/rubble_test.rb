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
end
