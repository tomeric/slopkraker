require "application_system_test_case"

# The first world made of real buildings on real ground. Everything here was asserted for
# years against hand-made worlds; this is where a rotated row, a heightfield from a survey
# and roads that are only drawn meet.
class GeleenTest < ApplicationSystemTestCase
  def boot(spawn: nil, match: "geleen-boot")
    visit root_path(params: { world: "geleen", quality: "low", match: match, spawn: spawn }.compact)
    wait_for(timeout: 60, message: "geleen never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
    # `ready` is the engine having booted, not the WORLD having run. Rapier builds its
    # broad phase inside `step`, so a raycast issued before the first one finds nothing
    # anywhere -- not a miss over a seam, nothing at all, silently. Every probe below
    # depends on that, and forty-eight buildings on a software rasteriser make the gap
    # between the two milestones wide enough to lose a race in.
    wait_for(timeout: 60, message: "the world never stepped") { page.evaluate_script("window.__arena.steps").positive? }
  end

  def telemetry = page.evaluate_script("window.__arena")

  def height_at(x, z) = page.evaluate_script("window.__arenaTerrainHeight(arguments[0], arguments[1])", x, z)

  # Wall-clock seconds are not simulation seconds in this world. Forty-eight buildings
  # rasterised in software hold the render loop to a few frames a second, and the
  # fixed-step accumulator caps its substeps, so sleeping for two seconds buys about a
  # quarter of a second of driving. Drive on the clock the car actually moves on.
  def drive(input, steps)
    from = page.evaluate_script("window.__arena.steps")
    page.execute_script("window.__arenaInput = arguments[0]", input)
    wait_for(timeout: 90, message: "the simulation never advanced #{steps} steps") do
      page.evaluate_script("window.__arena.steps") - from >= steps
    end
  ensure
    page.execute_script("window.__arenaInput = null")
  end

  teardown { page.execute_script("window.__arenaInput = null") }

  test "both islands boot with their buildings, roads and ground" do
    boot
    # Both islands, named rather than merely counted. A count alone passes on one island
    # loaded twice, which is exactly what a window put in the wrong place would produce.
    names = page.evaluate_script("window.__arenaBuildingIds().map(i => window.__arenaBuildingSpec(i).name)")
    assert_operator names.length, :>=, 40, "the import produced #{names.length} buildings"
    assert_operator names.count { |name| name.start_with?("estate-") }, :>, 10, "the estate is missing"
    assert_operator names.count { |name| name.start_with?("church-") }, :>, 10, "the church island is missing"
    assert_empty severe_console_errors
    assert_operator page.evaluate_script("window.__arenaRoadVertices()"), :>, 1000, "the roads are not drawn"
    # The estate stands about five metres above origin_z, the church about three below.
    assert_in_delta 4.5, height_at(1330, -2234), 2.0
    assert_in_delta(-4.5, height_at(2006, -1447), 3.0)
    # A quarter metre off the grid lines, as terrain_test surveys the seams: a ray exactly
    # on a row or column line can miss the heightfield outright, which is a raycast quirk
    # at a measure-zero set rather than a disagreement about where the ground is.
    probe = page.evaluate_script("window.__arenaTerrainProbe(1332.5, -2236.5)")
    assert probe["physics"], "no physics ground under the estate"
    assert_operator probe["delta"].abs, :<, 1e-3, "physics and render disagree about the ground"
  end

  test "the second spawn is beside the church" do
    boot(spawn: 1)
    x, _, z = page.evaluate_script("window.__arenaVehiclePos()")
    assert_in_delta 2006, x, 30
    assert_in_delta(-1415, z, 30)
  end

  test "a car driven from the estate spawn stays on the ground" do
    boot(match: "geleen-drive")

    # It settles on the survey before it is asked to do anything with it. The spawn is
    # computed from the DEM at seed time, so a car that arrived floating or buried would
    # say the seeder and the heightfield disagree.
    wait_for(timeout: 30, message: "the car never settled on the terrain") { telemetry["grounded"] == 4 }
    assert_clearance telemetry

    drive({ throttle: 1 }, 240)

    t = telemetry
    assert_operator t["grounded"], :>, 0, "the wheels lost the heightfield"
    assert_clearance t
  end

  test "a row's plate names its category and its Pand" do
    boot
    plate = page.evaluate_script("window.__arenaBuildingLabels().find(l => l.category === 'house')")
    assert plate, "no house plate"
    assert_match(/\A\d{6}\z/, plate["ids"].first)
  end

  private
    # The band terrain_test measured the truck's chassis at over the hills heightfield.
    # Below it the car has sunk into ground it is drawn standing on; above it, it is
    # resting on something that is not the ground.
    def assert_clearance(t)
      clearance = t["y"] - height_at(t["x"], t["z"])
      assert_operator clearance, :>, 0.2, "the car sank into the ground"
      assert_operator clearance, :<, 2.5, "the car is floating above the ground it is drawn on"
    end
end
