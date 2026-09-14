require "application_system_test_case"

class CollapseTest < ApplicationSystemTestCase
  # The piece hooks rather than a run-up at the wall: the assertion is about the round
  # trip, not about whether a car can reach a house inside the clock.
  #
  # __arenaDamagePiece and not __arenaBreak, deliberately. Breaking goes straight to
  # breakCell, which is also how a server-applied break lands, so it reports nothing --
  # damaging is the path a real hit takes and the only one that tells the server anything.
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

  # Its own match per test. Damage persists now, so sharing one would mean each test
  # booting into whatever the last one knocked down.
  def boot(match)
    visit_world("targets", vehicle: "buggy", match: match)
    wait_for(message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
    page.evaluate_script("window.__arenaBuildingIds()[0]")
  end

  def piece_standing?(building, index)
    page.evaluate_script("window.__arenaPieceState(arguments[0], arguments[1]).standing", index, building)
  end

  def roof_offset(building)
    page.evaluate_script(<<~JS, building)
      window.__arenaBuildingSpec(arguments[0]).surfaces.find(s => s.kind === "roof").off
    JS
  end

  # The whole loop in one assertion: the client reports what it broke, the server runs a
  # rule that exists nowhere in JavaScript, and the roof comes down here.
  test "knocking out two ground floor walls brings the house down" do
    building = boot("collapse-round-trip")
    wreck_storey(building, 0)

    wait_for(timeout: 15, message: "the server never reported a collapse") do
      page.evaluate_script("window.__arenaCollapses()").positive?
    end

    refute piece_standing?(building, roof_offset(building)),
           "the roof should have come down with the storeys below it"
  end

  # The client cannot have worked this out for itself -- nothing in JavaScript knows what a
  # collapse is. If the roof is down, a message said so.
  test "the client never decides a collapse on its own" do
    building = boot("collapse-untouched")

    assert_equal 0, page.evaluate_script("window.__arenaCollapses()")
    assert piece_standing?(building, roof_offset(building)), "the roof starts up"
  end

  # Coming back to a ruin must be silent. Restoring is not an event: the pieces were broken
  # in some earlier session, possibly by someone else, and staging the explosion again on
  # every page load is the difference between a world that persists and a world that blows
  # up in your face each time you open it.
  test "returning to a wrecked building does not set it off again" do
    building = boot("debris-restore")
    wreck_storey(building, 0)
    wait_for(timeout: 15, message: "the server never reported a collapse") do
      page.evaluate_script("window.__arenaCollapses()").positive?
    end
    Game::Damage::Registry.flush_all!

    boot("debris-restore")
    wait_for(timeout: 15, message: "the wreckage never came back") do
      !piece_standing?(building, 0)
    end

    assert_equal 0, page.evaluate_script("window.__arenaDebrisSpawned()"),
                 "restoring a ruin re-staged its demolition"
  end

  # ...but a break happening now still throws shards, or breaking things stops being fun.
  test "a break that happens now still throws debris" do
    building = boot("debris-live")
    page.execute_script("window.__arenaDamagePiece(0, 5000, arguments[0])", building)

    spawned = wait_for(timeout: 15, message: "a live break threw no debris") do
      count = page.evaluate_script("window.__arenaDebrisSpawned()")
      count.positive? && count
    end

    assert_operator spawned, :>, 0
  end

  # The process-restart case from the design doc, and the only version of this test worth
  # having. Dropping the registry is what makes it real: the server's memory of this match
  # is gone, so anything that comes back can only have come from object_damages. Reloading
  # the page alone would be served out of memory and prove nothing about the rows.
  test "damage survives the process that recorded it" do
    building = boot("collapse-reload")
    page.execute_script("window.__arenaDamagePiece(0, 5000, arguments[0])", building)

    wait_for(timeout: 15, message: "the break never reached the server") do
      page.evaluate_script("window.__arenaReported()").positive?
    end
    # The sweeper does not run under test, so ask for the write rather than sleeping on a
    # timer and hoping. What is being proved here is that the rows are enough to rebuild
    # from, not how often something writes them.
    Game::Damage::Registry.flush_all!
    assert_operator ObjectDamage.joins(:match).where(matches: { key: "collapse-reload" }).sum(:broken_count),
                    :>, 0, "the break was never written down"

    Game::Damage::Registry.reset!
    boot("collapse-reload")

    assert_equal 0, page.evaluate_script("window.__arenaReported()"),
                 "this session reported nothing, so anything broken came from the rows"
    refute piece_standing?(building, 0), "the wreckage did not come back"
  end
end
