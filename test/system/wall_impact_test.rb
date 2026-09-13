require "application_system_test_case"

# Driving at a wall has to break it. Obvious, and it was not true: the numbers made a solid
# hit land one point short of finishing a brick panel, so the wall took damage, went dark,
# and stood there. From the driver's seat that is indistinguishable from nothing happening.
class WallImpactTest < ApplicationSystemTestCase
  # The house stands at world x 20..32, z 8..23, so its front face is the z = 8 wall.
  FRONT_X = 26
  RUN_UP_Z = -22

  # The buggy, deliberately. Sustained full throttle from a standing start puts the
  # monster truck into a wheelie and then onto its roof, so it arrives at the wall
  # upside down or not at all -- which makes a perfectly good assertion about walls fail
  # for reasons that have nothing to do with walls.

  setup do
    visit_world("targets", vehicle: "buggy")
    wait_for(message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
  end

  teardown { page.execute_script("window.__arenaInput = null") }

  test "driving into the front of the house breaks a hole in it" do
    charge

    assert_operator telemetry["piecesBroken"], :>, 0, "the house took the hit and stood there"
  end

  test "the hit lands on the wall rather than stopping short of it" do
    charge

    assert_operator telemetry["lastDamage"], :>, 0, "nothing was ever scored against the house"
  end

  # The point of hardness: the same run at the same speed should take out brick and leave
  # the steel lintels standing.
  test "a car gets through brick and not through steel" do
    charge

    broken = page.evaluate_script(<<~JS)
      (() => {
        const out = {}
        for (let i = 0; i < window.__arena.pieces; i += 1) {
          const piece = window.__arenaPieceState(i)
          if (!piece.standing && piece.material !== "void") {
            out[piece.material] = (out[piece.material] || 0) + 1
          }
        }
        return out
      })()
    JS

    assert_operator broken.fetch("brick", 0), :>, 0, "brick should give way to a good hit"
    assert_equal 0, broken.fetch("steel", 0), "a lintel is not something you drive through"
  end

  private
    def charge
      page.execute_script("window.__arenaPlace = { x: #{FRONT_X}, y: 2.0, z: #{RUN_UP_Z}, yaw: 0 }")
      sleep 1.0
      page.execute_script("window.__arenaInput = { throttle: 1 }")
      sleep 4.0
      page.execute_script("window.__arenaInput = null")
      sleep 0.5
    end

    def telemetry
      page.evaluate_script("window.__arena")
    end
end
