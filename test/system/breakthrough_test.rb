require "application_system_test_case"

# Going through a wall has to leave you going somewhere.
#
# A building piece is a FIXED collider, and a step runs world.step -> drain contacts ->
# apply damage -> disable collider. So the solver always resolves the car against a wall
# that is still immovable, and the hole only exists afterwards -- by which point the
# momentum is gone too. The truck demolished a house and stopped dead in the gap it had
# just made, which from the driver's seat reads as having bounced off it.
#
# Its own match, because it knocks a hole in the house and damage persists: sharing the
# default lobby would mean arriving at a wall somebody else's test already took out.
class BreakthroughTest < ApplicationSystemTestCase
  # The house stands at world x 20..32, z 8..23, so its front face is the z = 8 wall.
  FRONT_X = 26
  RUN_UP_Z = -22

  setup do
    visit_world("targets", vehicle: "monster_truck", match: "breakthrough")
    wait_for(message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
  end

  teardown { page.execute_script("window.__arenaInput = null") rescue nil }

  test "the truck carries on through a wall it destroys" do
    run = charge

    assert_operator run["broken"], :>, 0, "the truck never reached the wall"
    assert_operator run["after"], :>, 4.0,
      "the truck stopped in the hole it made (#{run["before"].round(1)} m/s into the wall, " \
      "#{run["after"].round(1)} m/s out of it)"
  end

  # The other half, and the one that stops this becoming "walls are free". A wall you go
  # through still costs you what it was worth -- the health you destroyed, converted back
  # through the same damage-per-speed the hit was scored with.
  test "the wall still takes something out of it" do
    run = charge

    assert_operator run["broken"], :>, 0, "the truck never reached the wall"
    assert_operator run["after"], :<, run["before"],
      "going through a wall cost the truck nothing (#{run["before"].round(1)} m/s in, " \
      "#{run["after"].round(1)} m/s out)"
  end

  # Requirement three, for the truck. A collapsed house's wreckage is something the truck
  # clears THROUGH rather than climbs or stops against: the wheel rays pass through the
  # heaps, the blade breaks the ones tall enough to meet it, and the truck comes out the
  # far side still moving, having cleared some of them on the way.
  #
  # Asserted as arrival rather than as a speed profile, because arrival is what the driver
  # sees and a speed sampled from Ruby is a lottery. The margin is the whole house: the
  # pile spans z 8..23 and the truck has to be past 24. Measured when this was written: in
  # at 13.7 m/s, never below 12 across the pile, nineteen heaps cleared, out in 4.5s.
  # Before the wheel rays were told to ignore heaps it rode up onto the rim, cleared none,
  # and stalled on top of the mound.
  test "the truck ploughs through a fallen house's wreckage" do
    building = page.evaluate_script("window.__arenaBuildingIds()[0]")
    page.execute_script(<<~JS, building)
      const id = arguments[0]
      const spec = window.__arenaBuildingSpec(id)
      const walls = spec.surfaces.filter(s => s.kind === "wall" && s.storey === 0)
      for (const s of walls.slice(0, 2)) {
        for (let i = s.off; i < s.off + s.cols * s.rows; i++) window.__arenaDamagePiece(i, 5000, id)
      }
    JS
    wait_for(timeout: 25, message: "the house never came down") do
      page.evaluate_script("window.__arenaFalling() === 0 && window.__arenaRubble().dormant === 0")
    end
    assert_operator page.evaluate_script("window.__arenaRubble().standing"), :>, 0, "nothing to plough through"

    page.execute_script("window.__arenaPlace = { x: #{FRONT_X}, y: 2.0, z: -14, yaw: 0 }")
    sleep 1.0
    page.execute_script("window.__arenaInput = { throttle: 1 }")

    wait_for(timeout: 12, message: "the truck never came out the far side of the wreckage") do
      page.evaluate_script("window.__arena.z") > 24
    end
    page.execute_script("window.__arenaInput = null")

    assert_operator page.evaluate_script("window.__arenaRubble().cleared"), :>, 0,
                    "the truck crossed the site without clearing a single heap"
  end

  private
    # Sampled from inside the page at 5ms. Selenium round trips are slower than the
    # breakthrough itself: by the time a poll from Ruby lands, the truck has either driven
    # out the far side or been sitting still for a while, and both look the same.
    #
    # `before` is the fastest the truck went with the wall still whole, `after` the speed
    # a beat later -- long enough to be clear of the wall, short enough that it is still
    # inside the fifteen metre house and ordinary rolling resistance has not become the
    # thing being measured.
    def charge
      page.execute_script("window.__arenaPlace = { x: #{FRONT_X}, y: 2.0, z: #{RUN_UP_Z}, yaw: 0 }")
      sleep 1.0
      page.execute_script(<<~JS)
        window.__run = { before: 0, after: 0, broken: 0, at: 0, done: false }
        window.__runTimer = setInterval(() => {
          const a = window.__arena
          if (!a) return
          const r = window.__run
          if (!r.broken) {
            // The peak of the run-up, not the last sample before the break. This poll is
            // asynchronous to the physics step, so "the last one before" can already be a
            // frame the solver has stopped the truck on.
            r.before = Math.max(r.before, a.planarSpeed)
            if (a.piecesBroken > 0) { r.broken = a.piecesBroken; r.at = performance.now() }
            return
          }
          if (r.at && performance.now() - r.at >= 300) {
            r.after = a.planarSpeed
            r.at = 0
            r.done = true
          }
        }, 5)
      JS

      page.execute_script("window.__arenaInput = { throttle: 1 }")
      # Waited for rather than slept through. Thirty metres of run-up takes the truck most
      # of four seconds, so a fixed drive long enough to reach the wall is not reliably
      # long enough to still be running a beat after it -- which reads as a truck that
      # stopped, and is the same failure as the bug this covers.
      run = wait_for(timeout: 15, message: "the truck never reached the wall") do
        sampled = page.evaluate_script("window.__run")
        sampled["done"] && sampled
      end
      page.execute_script("window.__arenaInput = null")
      page.execute_script("clearInterval(window.__runTimer)")
      run
    end
end
