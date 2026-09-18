require "application_system_test_case"

# What a street proves that a single house cannot.
#
# Every claim the building code makes about scale -- one draw call per material across ALL
# buildings, one shared spatial grid, one shared pool of falling slabs, collapses that stay
# independent of one another -- was until now asserted against a world containing exactly
# one house. With one building the shared thing and the per-building thing are the same
# thing, so none of those claims was under test at all. One of them was false.
class StreetTest < ApplicationSystemTestCase
  # Solo slab counts, measured on this street. house_west_3 is the largest building here --
  # four storeys on a one metre grid -- and the three of these together promise more slabs
  # than the air is allowed to hold, which is the whole point of the last test.
  BIGGEST = "house_west_3".freeze

  def boot(match, world: "street")
    visit_world(world, vehicle: "buggy", match: match)
    wait_for(message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
    page.evaluate_script(<<~JS)
      window.__id = (name) => window.__arenaBuildingIds().find(i => window.__arenaBuildingSpec(i).name === name)
    JS
  end

  def id_of(name)
    page.evaluate_script("window.__id(arguments[0])", name)
  end

  # Two ground floor walls, which is what it takes to lose a storey. Damage rather than
  # break: breaking goes straight to breakCell, which is also how a server-applied break
  # lands, so it reports nothing and no collapse is ever decided.
  def wreck_ground_floor(names)
    page.execute_script(<<~JS, names)
      for (const name of arguments[0]) {
        const id = window.__id(name)
        const spec = window.__arenaBuildingSpec(id)
        const walls = spec.surfaces.filter(s => s.kind === "wall" && s.storey === 0)
        for (const s of walls.slice(0, 2)) {
          for (let i = s.off; i < s.off + s.cols * s.rows; i++) window.__arenaDamagePiece(i, 5000, id)
        }
      }
    JS
  end

  def collapses_seen
    page.evaluate_script("window.__arenaCollapses()")
  end

  def slabs_dropped(name)
    page.evaluate_script("window.__arenaSlabsDropped(window.__id(arguments[0]))", name)
  end

  def total_slabs_dropped
    page.evaluate_script(<<~JS)
      window.__arenaBuildingIds().reduce((n, id) => n + window.__arenaSlabsDropped(id), 0)
    JS
  end

  def standing_in(name)
    page.evaluate_script("window.__arenaBuildingStanding(window.__id(arguments[0]))", name)
  end

  def falling_budget
    Game::Spec.default_rules.dig(:collapse, :fall)
  end

  # The claim that makes a city conceivable, and the reason the meshes are shared across
  # buildings rather than owned by them. Twelve houses and 6692 pieces must not cost more
  # draw calls than one house and 1502 -- if the render plan ever regressed to a pool per
  # building, this is where it would show up, as roughly a hundred draws instead of thirty.
  #
  # Measured against the one-house world rather than a written-down number, because the
  # claim is a comparison: draws track MATERIALS, never buildings.
  test "twelve houses cost no more draw calls than one house" do
    boot("street-draws", world: "targets")
    # The debug overlay puts one label plate above every building in range -- a draw call
    # each, and a diagnostic rather than the render plan this test guards. Hide it before
    # counting draws in either world.
    page.driver.browser.action.key_down("g").key_up("g").perform
    wait_for(message: "debug view never hid") { page.evaluate_script("window.__arenaDebugVisible") == false }
    sleep 0.3
    one_house = page.evaluate_script("window.__arenaDraws()")
    one_house_pieces = page.evaluate_script("window.__arena.pieces")

    boot("street-draws")
    # Same here: the street has more buildings in range than the targets world, so left on
    # it would show more plates and cost more draws for a reason that has nothing to do
    # with piece meshes.
    page.driver.browser.action.key_down("g").key_up("g").perform
    wait_for(message: "debug view never hid") { page.evaluate_script("window.__arenaDebugVisible") == false }
    sleep 0.3
    street = page.evaluate_script("window.__arenaDraws()")
    street_pieces = page.evaluate_script("window.__arena.pieces")

    assert_equal 12, page.evaluate_script("window.__arenaBuildingIds().length")
    assert_operator street_pieces, :>, one_house_pieces * 4,
                    "the street should carry several times the geometry of one house"
    assert_operator street, :<=, one_house,
                    "#{street_pieces} pieces across twelve buildings cost #{street} draws, " \
                    "against #{one_house} for #{one_house_pieces} pieces in one -- " \
                    "the instanced pools are no longer shared across buildings"
  end

  # Collapses must be independent, and nothing about one building may reach another.
  #
  # standingCount is the right reading to take because it moves in BOTH directions that
  # would matter: a piece of the neighbour breaking takes it down, and a heap of the
  # neighbour's rubble being revealed by somebody else's collapse puts it up -- revealing
  # moves a piece DORMANT -> INTACT. Exactly unchanged is the only number that says
  # neither happened.
  test "collapsing one house leaves the one next door untouched" do
    boot("street-independence")
    neighbour_before = standing_in("house_east_2")
    victim_before = standing_in("house_east_1")

    wreck_ground_floor([ "house_east_1" ])
    wait_for(timeout: 20, message: "the server never reported a collapse") { collapses_seen.positive? }
    wait_for(timeout: 20, message: "the collapse never finished falling") do
      page.evaluate_script("window.__arenaFalling()").zero?
    end

    assert_operator standing_in("house_east_1"), :<, victim_before,
                    "the house that was condemned is still standing, so nothing was proved"
    assert_equal neighbour_before, standing_in("house_east_2"),
                 "the house next door changed while its neighbour came down"
    assert_equal 1, collapses_seen, "a second building was condemned by the first one's collapse"
  end

  # The per-building half of the budget. Two houses condemned together must each fall in
  # full -- neither is thinned on account of the other -- which is what `per_building`
  # being a separate number from `max` buys.
  test "two houses coming down together each fall in full" do
    boot("street-solo")
    wreck_ground_floor([ BIGGEST ])
    wait_for(timeout: 20, message: "no collapse") { collapses_seen.positive? }
    alone = slabs_dropped(BIGGEST)
    assert_operator alone, :>, 0, "the biggest house put nothing in the air on its own"

    boot("street-together")
    wreck_ground_floor([ BIGGEST, "house_east_4" ])
    wait_for(timeout: 20, message: "both houses never came down") { collapses_seen >= 2 }

    assert_equal alone, slabs_dropped(BIGGEST),
                 "the biggest house fell less fully with a neighbour coming down beside it"
    assert_operator slabs_dropped(BIGGEST) + slabs_dropped("house_east_4"), :>, falling_budget[:per_building],
                    "the two of them shared one building's allowance instead of having their own"
  end

  # The bug this street was built to find.
  #
  # FallingPieces is shared by every building, but the budget was read as though the whole
  # of it were free however much was already up there -- so a second collapse would drop
  # its full complement on top of a first one's, and the ring would make room by taking the
  # OLDEST slabs out of the air. Those belonged to the house that was still falling. They
  # shattered in the sky and reported home that they had landed, which revealed that
  # house's rubble early, under a building that had not finished coming down.
  #
  # Measured before the fix: seven houses condemned together promised 1325 slabs against a
  # ceiling of 1200, and the 125 that did not fit were taken from buildings mid-descent.
  # Nothing downstream looks wrong when this happens, which is why it needed asserting
  # rather than watching.
  #
  # In waves because the server keeps only the first 512 hits of a batch and drops the
  # rest; a whole street reported in one frame loses hits and this stops being about
  # falling slabs at all.
  test "a street coming down at once never promises more slabs than the air can hold" do
    condemned = [
      BIGGEST, "house_east_4", "house_east_1", "house_west_5", "house_east_2",
      "house_west_1", "house_east_5"
    ]
    boot("street-oversubscribed")

    condemned.each_slice(3) { |wave| wreck_ground_floor(wave) }
    wait_for(timeout: 30, message: "the street never came down") { collapses_seen >= condemned.size }

    promised = total_slabs_dropped
    assert_operator promised, :>, falling_budget[:per_building],
                    "not enough of the street came down for this to be about a shared budget"
    assert_operator promised, :<=, falling_budget[:max],
                    "#{condemned.size} buildings promised #{promised} slabs against a ceiling of " \
                    "#{falling_budget[:max]} -- the excess was taken from buildings still in the air"
  end
end
