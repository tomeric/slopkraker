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

  # Watched from inside the page for the PEAK, not read off the end. Since a car that breaks
  # a wall carries on through the hole, the buggy goes through the front wall, the partition
  # and out through the back, and its final contact is a slow scrape against whatever it
  # comes to rest on -- which scores nought and overwrote a perfectly good hit. Measured: 33
  # on the front wall, 24 on the back, then 1 or 0 at the end of the run.
  test "the hit lands on the wall rather than stopping short of it" do
    page.execute_script(<<~JS)
      window.__peakDamage = 0
      ;(function sample() {
        const a = window.__arena
        if (a && a.lastDamage > window.__peakDamage) window.__peakDamage = a.lastDamage
        requestAnimationFrame(sample)
      })()
    JS
    charge

    assert_operator page.evaluate_script("window.__peakDamage"), :>, 0,
                    "nothing was ever scored against the house"
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

  # A rocket has to reach the building at all, and for a while it did not. The blast wave
  # sweeps the spatial grid, and only loose props were ever put into it -- so explosions
  # found crates and pillars and passed straight through walls, at any damage number you
  # care to set.
  #
  # Then, once pieces were in the grid, breaking one removed it from a cell mid-sweep while
  # damage spread was breaking its neighbours out of that same cell. The array shrank under
  # a loop that had captured its length once, the sweep threw, and every target it had not
  # reached yet was lost. Both failures look identical from the driver's seat: a bang, and a
  # wall still standing.
  test "a rocket blows a hole in the house" do
    standing = telemetry["piecesStanding"]
    fire_from(2)

    assert_operator telemetry["piecesBroken"], :>, 20,
      "one rocket should take out a good part of a wall"
    assert_operator telemetry["piecesStanding"], :<, standing
    assert_empty severe_console_errors, "the sweep threw part way through"
  end

  test "a blast leaves shards behind" do
    fire_from(2)

    assert_operator telemetry["shards"], :>, 0, "a blast should throw debris"
  end

  private
    def fire_from(z)
      page.execute_script("window.__arenaPlace = { x: #{FRONT_X}, y: 2.0, z: #{z}, yaw: 0 }")
      sleep 1.0
      page.execute_script("window.__arenaInput = { action: true, actionPressed: true }")
      sleep 0.3
      page.execute_script("window.__arenaInput = null")
      sleep 2.5
    end

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
