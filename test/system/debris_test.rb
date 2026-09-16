require "application_system_test_case"

# The small stuff -- the shards a break throws, the chunks a cleared heap leaves lying --
# has no bodies, so nothing in the physics ever touches it. It is swept by hand instead: a
# car reaching it kicks it away and a blast throws it outward, and either way it is gone
# within the moment. Without this a car parked in a debris field sat in shards that ignored
# it, which reads as the shards being painted on.
#
# The buggy for both, because one of them needs a rocket.
class DebrisTest < ApplicationSystemTestCase
  # The house stands at world x 20..32, z 8..23; its front face is the z = 8 wall.
  FRONT_X = 26

  def boot(match)
    visit_world("targets", vehicle: "buggy", match: match)
    wait_for(message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
    page.evaluate_script("window.__arenaBuildingIds()[0]")
  end

  teardown { page.execute_script("window.__arenaInput = null") rescue nil }

  # Break the ground course of the front wall, which showers shards onto the ground in front
  # of the house around z = 8. Broken, not damaged: a break reports nothing to the server, so
  # no collapse is ever decided and the shards are the only thing that changes.
  def shower_shards(building)
    page.execute_script(<<~JS, building)
      const id = arguments[0]
      const front = window.__arenaBuildingSpec(id).surfaces[0]
      for (let col = 0; col < front.cols; col++) window.__arenaBreak(front.off + col, id)
    JS
    wait_for(timeout: 5, message: "the breaks threw no shards") { page.evaluate_script("window.__arena.shards").positive? }
  end

  def kicked = page.evaluate_script("window.__arenaDebrisKicked()")
  def kicked_live = page.evaluate_script("window.__arenaDebrisKickedLive()")
  def kicked_life = Game::Spec.default_rules.dig(:debris, :kicked_life)

  # Parked well clear before the shards fall, so nothing is kicked until the car moves.
  test "a car driving through shards kicks them away, and they are gone" do
    building = boot("debris-drive")
    page.execute_script("window.__arenaPlace = { x: #{FRONT_X}, y: 2.0, z: -12, yaw: 0 }")
    sleep 0.6
    shower_shards(building)
    assert_equal 0, kicked, "shards were kicked before anything reached them"

    page.execute_script("window.__arenaInput = { throttle: 1 }")
    wait_for(timeout: 8, message: "the car drove through the shards and touched none of them") { kicked.positive? }
    page.execute_script("window.__arenaInput = null")

    # Out of the debris entirely, then long enough for anything kicked to be gone.
    page.execute_script("window.__arenaPlace = { x: #{FRONT_X}, y: 2.0, z: -40, yaw: 0 }")
    sleep kicked_life + 0.8
    assert_equal 0, kicked_live, "kicked shards were still lying there"
  end

  # A blast throws whatever was already lying in its shell -- but not the shards it throws
  # itself, which is what the grace period is for and what the last assertion covers.
  test "a blast throws the shards lying in it away" do
    building = boot("debris-blast")
    page.execute_script("window.__arenaPlace = { x: #{FRONT_X}, y: 2.0, z: 0, yaw: 0 }")
    sleep 0.6
    shower_shards(building)
    sleep 1.5
    assert_equal 0, kicked, "the parked car should not have reached the shards"

    page.execute_script("window.__arenaInput = { action: true, actionPressed: true }")
    sleep 0.3
    page.execute_script("window.__arenaInput = null")

    wait_for(timeout: 6, message: "the blast left the shards where they were") { kicked.positive? }
    sleep 2.5
    assert_operator page.evaluate_script("window.__arena.shards"), :>, 0,
                    "the blast swept away the shards it had just thrown itself"
  end
end
