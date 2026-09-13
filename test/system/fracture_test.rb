require "application_system_test_case"

# Breaking something leaves shards behind, and what the shards look like depends on what
# broke: glass throws far more, and smaller, than brick does.
class FractureTest < ApplicationSystemTestCase
  setup do
    visit_world("targets")
    wait_for(message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
  end

  test "breaking a piece leaves shards behind" do
    assert_equal 0, telemetry["shards"]

    page.execute_script("window.__arenaBreak(0)")

    wait_for(message: "nothing shattered") { telemetry["shards"] > 0 }
    assert_empty severe_console_errors
  end

  # The whole reason for a fracture library rather than one debris shape: a pane comes
  # apart into a shower and a brick panel into a handful of lumps.
  test "glass shatters into more pieces than brick" do
    brick = shards_from(first_piece_of("brick"))
    reload
    glass = shards_from(first_piece_of("glass"))

    assert_operator glass, :>, brick, "glass should come apart further than brick"
  end

  test "shards clear themselves up" do
    page.execute_script("window.__arenaBreak(#{first_piece_of("brick")})")
    wait_for(message: "nothing shattered") { telemetry["shards"] > 0 }

    wait_for(timeout: 25, message: "shards never expired") { telemetry["shards"].zero? }
    assert_equal 0, telemetry["shards"]
  end

  # A house is hundreds of pieces and a good hit takes out five at once. The cap is what
  # stops a determined player turning the frame rate into a slideshow.
  test "the shard budget holds under a barrage" do
    page.execute_script(<<~JS)
      for (let i = 0; i < 120; i += 1) window.__arenaBreak(i)
    JS

    wait_for(message: "nothing shattered") { telemetry["shards"] > 0 }
    assert_operator telemetry["shards"], :<=, 260
  end

  private
    def reload
      visit_world("targets")
      wait_for { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
    end

    def first_piece_of(material)
      page.evaluate_script(<<~JS)
        (() => {
          for (let i = 0; i < window.__arena.pieces; i += 1) {
            if (window.__arenaPieceState(i).material === "#{material}") return i
          }
          return -1
        })()
      JS
    end

    def shards_from(piece)
      page.execute_script("window.__arenaBreak(#{piece})")
      wait_for(message: "nothing shattered") { telemetry["shards"] > 0 }
      telemetry["shards"]
    end

    def telemetry
      page.evaluate_script("window.__arena")
    end
end
