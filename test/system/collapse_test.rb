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

  # Defensive rather than bare, so a missing hook fails as "nothing ever went up" with the
  # console errors attached, instead of as a ReferenceError from inside a poll.
  def in_the_air
    page.evaluate_script("window.__arenaFalling ? window.__arenaFalling() : 0")
  end

  def shards_thrown
    page.evaluate_script("window.__arenaDebrisSpawned()")
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

  # The point of the whole exercise. A house that has been condemned must come DOWN --
  # pieces in the air, under gravity, landing -- rather than being replaced by a cloud of
  # shards between one frame and the next.
  #
  # The ordering is what is actually asserted, and it is asserted without racing the
  # simulation: whatever shards had been thrown at the moment pieces were still in the air,
  # there are more of them once those pieces are down. A build that shatters on condemnation
  # never gets a positive reading out of __arenaFalling at all, and fails on the wait.
  test "a condemned storey falls before it shatters" do
    building = boot("collapse-falling")
    wreck_storey(building, 0)

    shards_at_launch = wait_for(timeout: 20, message: "the collapse put nothing in the air") do
      in_the_air.positive? && shards_thrown
    end

    wait_for(timeout: 20, message: "the falling pieces never came down") { in_the_air.zero? }

    assert_operator shards_thrown, :>, shards_at_launch,
                    "the pieces came down without shattering"
  end

  # The silent rule again, for the stage that did not exist when the test above it was
  # written. A ruin must not put anything in the air either: pieces raining onto a street
  # they came down in some session last week is the same lie as their shards, and a slower
  # one to notice, because this one lands on your car.
  test "returning to a wrecked building puts nothing in the air" do
    building = boot("falling-restore")
    wreck_storey(building, 0)
    wait_for(timeout: 15, message: "the server never reported a collapse") do
      page.evaluate_script("window.__arenaCollapses()").positive?
    end
    Game::Damage::Registry.flush_all!

    boot("falling-restore")
    wait_for(timeout: 15, message: "the wreckage never came back") { !piece_standing?(building, 0) }

    assert_equal 0, in_the_air, "a ruin restaged its own descent"
  end
  # The backstop is not the mechanism, and this is the test that says so.
  #
  # A piece that is already resting on something when it is condemned -- a ground floor
  # panel standing on the ground it is about to become rubble on -- gets exactly one
  # "contact started" from Rapier, at the moment it spawns. Throw that away and no second
  # one is ever coming, because it never stops touching what it is sitting on. Those pieces
  # then sit there for the whole of `life` and vanish together, which looks precisely as
  # wrong as it sounds.
  #
  # So: everything a collapse puts in the air is down long before the backstop could
  # explain it. The margin is what makes the assertion mean anything -- pieces genuinely
  # fall for about a second and a half, and `life` is six.
  test "every piece a collapse drops lands rather than timing out" do
    building = boot("falling-backstop")
    wreck_storey(building, 0)

    wait_for(timeout: 20, message: "the collapse put nothing in the air") { in_the_air.positive? }

    wait_for(timeout: 4, message: "pieces were still in the air, waiting out the backstop") do
      in_the_air.zero?
    end

    assert_equal 0, in_the_air, "the collapse came down under its own weight rather than on a timer"
  end
end
