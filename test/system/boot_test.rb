require "application_system_test_case"

# The engine comes up, steps, draws, and the world it was told to load is the world it
# actually loaded. Everything else in the suite assumes all of that.
class BootTest < ApplicationSystemTestCase
  test "the world boots, steps physics and renders without console errors" do
    visit_world("flat")

    assert_selector "canvas.arena__canvas", visible: :all

    wait_for(message: "the engine never reported ready") do
      page.evaluate_script("!!(window.__arena && window.__arena.ready)")
    end

    # Physics and rendering must actually advance, not merely initialise.
    wait_for(message: "physics never stepped") do
      page.evaluate_script("window.__arena.steps") > 0
    end
    wait_for(message: "nothing ever rendered") do
      page.evaluate_script("window.__arena.frames") > 0
    end

    assert_equal "monster_truck", page.evaluate_script("window.__arena.vehicle")
    assert_empty severe_console_errors, "console reported errors"
  end

  test "the world spec reaches the client intact" do
    visit_world("flat")

    spec = page.evaluate_script(<<~JS)
      JSON.parse(document.querySelector('[data-arena-target="spec"]').textContent)
    JS

    assert_equal %w[buggy monster_truck], spec["vehicles"].keys.sort
    assert_equal 12, spec["version"].length
    assert_equal [ 0.0, -9.81, 0.0 ], spec["arena"]["gravity"]
    assert_includes spec["arena"]["bodies"].map { |body| body["kind"] }, "ground"
    assert_not_empty spec["arena"]["spawns"]
    assert_nil spec["arena"]["terrain"], "flat is flat"
  end

  # The world parameter has to actually select a world, or every test that thinks it is
  # running somewhere narrow is quietly running somewhere else.
  test "the requested world is the one that loads" do
    visit_world("flat")
    assert_empty props_in_spec, "flat should carry nothing to break"

    visit_world("targets")
    assert_equal %w[crate crate crate pillar], props_in_spec.sort
  end

  # Props are the only things that move, so they are the only things interpolated. A world
  # with nothing to break legitimately tracks none.
  test "props are tracked for interpolation" do
    visit_world("targets")
    wait_for(message: "the engine never reported ready") do
      page.evaluate_script("!!(window.__arena && window.__arena.ready)")
    end

    assert_equal 4, page.evaluate_script("window.__arena.bodies")
  end

  private
    def props_in_spec
      page.evaluate_script(<<~JS)
        JSON.parse(document.querySelector('[data-arena-target="spec"]').textContent)
          .arena.props.map(p => p.kind)
      JS
    end
end
