require "application_system_test_case"

# A car that comes to rest on a pile of wreckage has to be able to get off it again.
#
# `grounded` means "a WHEEL RAY found ground", and the wheel rays are blind to rubble on
# purpose -- groups.js has the reasoning, and it is right: let them land on heaps and a
# truck rides up the pile instead of going through it. But the CHASSIS is still solid to a
# heap, so a car that comes to rest on one is held up by something none of its wheels can
# see. Every driving system then reads it as airborne, and it stays airborne for ever,
# because a heap is a fixed collider and nothing is going to move it.
#
# Measured before this was fixed, on the pile left by the targets house: two seconds of
# full throttle moved it 0.0 m/s, and twelve presses of the hop did nothing at all. Only
# the monster truck could leave, and only by flying -- its jets are the one input not
# gated on wheel contact. Respawning was the only way out for the buggy.
class StuckTest < ApplicationSystemTestCase
  # The mound over the targets house, which stands at x 20..32, z 8..23.
  OVER_THE_PILE = { x: 26, y: 14.0, z: 15.5 }.freeze

  def boot(vehicle, match)
    visit_world("targets", vehicle: vehicle, match: match)
    wait_for(message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
    page.evaluate_script("window.__arenaBuildingIds()[0]")
  end

  # Take the ground storey out from under it and wait for the dust. Heaps arrive as the
  # slabs carrying them land, so "some wreckage" and "all of it" are a second apart.
  def flatten(building)
    page.execute_script(<<~JS, building)
      const id = arguments[0]
      const spec = window.__arenaBuildingSpec(id)
      for (const s of spec.surfaces.filter(x => x.kind === "wall" && x.storey === 0)) {
        for (let i = s.off; i < s.off + s.cols * s.rows; i++) window.__arenaDamagePiece(i, 5000, id)
      }
    JS
    wait_for(timeout: 30, message: "the site never settled") do
      page.evaluate_script("window.__arenaFalling()").zero? &&
        page.evaluate_script("window.__arenaRubble()")["dormant"].zero?
    end
  end

  def drop_onto_the_pile(vehicle, match)
    building = boot(vehicle, match)
    flatten(building)
    page.execute_script("window.__arenaPlace = #{OVER_THE_PILE.to_json}")
    sleep 2.0
    building
  end

  def height = page.evaluate_script("window.__arenaVehiclePos()")[1]
  def arena = page.evaluate_script("window.__arena")

  teardown { page.execute_script("window.__arenaInput = null") rescue nil }

  # The pile is some three metres in the middle and the car lands on top of it. Left alone,
  # its own weight has to bring it down to the ground -- wreckage is something you go
  # THROUGH, and that has to hold for a car sitting on it as well as one driving at it.
  test "a car left sitting on the pile sinks through it" do
    drop_onto_the_pile("buggy", "stuck-sinks")
    perched = height
    assert_operator perched, :>, 2.0, "the car never landed on the pile to begin with"

    wait_for(timeout: 12, message: "the car perched on the pile for ever") do
      arena["grounded"] > 0
    end

    assert_operator height, :<, perched - 1.0,
      "the car is still up the pile (#{perched.round(2)}m, now #{height.round(2)}m)"
  end

  # The hop is the one control a player reaches for to shake a car loose, and it was
  # refused for exactly as long as it was needed: it is gated on wheel contact, and having
  # no wheel in contact is the whole of being stuck.
  #
  # The CHANGE in vertical speed is what is asserted, and both halves of that matter.
  #
  # Sampled inside the page, because a hop is one impulse and gravity starts taking it back
  # at once -- a reading fetched a Selenium round trip later is already negative whether or
  # not the hop fired. And measured as a delta rather than against a fixed figure, because
  # the car is not sitting still when the hop is pressed: it is crushing its way down
  # through the pile, so it is already going downward at a speed that varies per run.
  #
  # The hop is worth impulse/mass -- 2400/900 = 2.65 m/s on the buggy -- so anything over a
  # metre a second is the hop and nothing else.
  test "the hop fires while the car is resting on wreckage" do
    drop_onto_the_pile("buggy", "stuck-hop")
    assert_equal 0, arena["grounded"], "this test is meaningless unless no wheel is in contact"

    page.execute_script(<<~JS)
      window.__hop = { first: null, peak: -Infinity }
      window.__hopTimer = setInterval(() => {
        if (!window.__arena) return
        const y = window.__arena.verticalSpeed
        if (window.__hop.first === null) window.__hop.first = y
        window.__hop.peak = Math.max(window.__hop.peak, y)
      }, 5)
    JS
    page.execute_script("window.__arenaInput = { slide: true, slidePressed: true }")
    sleep 0.4
    page.execute_script("window.__arenaInput = null")
    hop = page.evaluate_script("window.__hop")
    page.execute_script("clearInterval(window.__hopTimer)")

    assert_operator hop["peak"] - hop["first"], :>, 1.0,
      "the hop did not fire while the car was perched " \
      "(#{hop["first"].round(2)} m/s before, peaked at #{hop["peak"].round(2)})"
  end

  # The catch-all, for whatever else a car can come to rest on. Nothing may hold a car for
  # ever, and before this the only way out was to respawn.
  #
  # Landing INVERTED on the pile is the case that reaches it, and it is a real one rather
  # than a contrivance: the car crushes its way down through the wreckage on its roof, and
  # arrives at the bottom upside down on the ground, where there is no longer any wreckage
  # under it to crush and no wheel that can reach anything. Measured: motionless from there
  # on, and shaken loose a couple of seconds later.
  test "a car that cannot move at all is shaken loose" do
    building = boot("buggy", "stuck-unstick")
    flatten(building)
    page.execute_script("window.__arenaPlace = #{{ x: 26, y: 8.0, z: 15.5, yaw: 0 }.to_json}")
    sleep 0.2
    page.execute_script("window.__arenaFlip = true")

    assert_equal 0, page.evaluate_script("window.__arenaUnstuck()"),
      "nothing should have been shaken loose before the car has even landed"

    wait_for(timeout: 25, message: "the car was never shaken loose") do
      page.evaluate_script("window.__arenaUnstuck()") > 0
    end
  end

  # The other half of the catch-all, and the half that would actually be felt if it were
  # wrong: a car in mid-air is not stuck, it is jumping, and throwing it again at the top
  # of its arc would be a bug the player could see every single time.
  test "nothing is shaken loose in ordinary driving" do
    boot("monster_truck", "stuck-ordinary")

    page.execute_script("window.__arenaInput = { throttle: 1 }")
    sleep 2.0
    page.execute_script("window.__arenaInput = { throttle: 1, slide: true, slidePressed: true }")
    sleep 0.3
    page.execute_script("window.__arenaInput = { throttle: 1, action: true, actionPressed: true }")
    sleep 2.0
    page.execute_script("window.__arenaInput = { throttle: 1 }")
    sleep 2.5

    assert_equal 0, page.evaluate_script("window.__arenaUnstuck()"),
      "a car that was driving, hopping and flying was shaken loose as though it were stuck"
  end
end
