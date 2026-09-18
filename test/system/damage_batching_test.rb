require "application_system_test_case"

# A frame that breaks more cells than one message may carry must still reach the server
# whole. Measured before this: a church's ground storey knocked out in one frame arrived as
# exactly 512 broken pieces, and the collapse the client was owed never came.
class DamageBatchingTest < ApplicationSystemTestCase
  test "a thousand breaks in one frame all reach the server" do
    visit_world("targets", match: "damage-batching")
    wait_for(message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }

    id = page.evaluate_script("window.__arenaBuildingIds()[0]")
    broke = page.evaluate_script(<<~JS, id)
      (() => {
        const id = arguments[0]
        const spec = window.__arenaBuildingSpec(id)
        const before = window.__arenaBuildingStanding(id)
        for (const s of spec.surfaces.filter(s => s.kind === "floor" || s.kind === "roof")) {
          for (let i = s.off; i < s.off + s.cols * s.rows; i++) window.__arenaDamagePiece(i, 5000, id)
        }
        return before - window.__arenaBuildingStanding(id)
      })()
    JS
    assert_operator broke, :>, Game::Damage::MatchState::MAX_HITS_PER_BATCH, "not enough broke for the cap to matter"

    match = Match.find_by!(key: "damage-batching")
    wait_for(timeout: 15, message: "the server never caught up") do
      Game::Damage::Registry.checkout(match) { |state| state.state_for([ id ]).first["broken_count"] } == broke
    end
    assert_empty page.evaluate_script("window.__arenaNetErrors()"), "the client should never be told it was truncated"
  end
end
