require "application_system_test_case"

# The ground has elevation, the car stands on it, and what it stands on is what is drawn.
class TerrainTest < ApplicationSystemTestCase
  def boot(match)
    visit_world("hills", match: match)
    wait_for(message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
    # `ready` is the engine, not the world: Rapier builds its broad phase inside `step`, so
    # a raycast issued before the first one finds nothing anywhere -- not a miss, nothing.
    wait_for(timeout: 60, message: "the world never stepped") { page.evaluate_script("window.__arena.steps").positive? }
  end

  def height_at(x, z)
    page.evaluate_script("window.__arenaTerrainHeight(arguments[0], arguments[1])", x, z)
  end

  def telemetry
    page.evaluate_script("window.__arena")
  end

  def drive(input, seconds)
    page.execute_script("window.__arenaInput = arguments[0]", input)
    sleep seconds
    page.execute_script("window.__arenaInput = null")
  end

  teardown { page.execute_script("window.__arenaInput = null") }

  # The wheels are raycasts on WHEEL_RAY_GROUPS, which excludes only rubble, so they should
  # find a heightfield with no change. Should is not did.
  test "the car settles on the hilltop it spawns over" do
    boot("terrain-spawn")
    assert_in_delta 7.7, height_at(0.0, 0.0), 0.05, "the hilltop is not where the function puts it"

    sleep 1.5
    t = telemetry
    assert_equal 4, t["grounded"], "all four wheels should be on the heightfield"
    clearance = t["y"] - height_at(t["x"], t["z"])
    assert_operator clearance, :>, 0.2, "the car sank into the ground"
    assert_operator clearance, :<, 2.5, "the car is floating above the ground it is drawn on"
  end

  test "the car drives down the slope on its wheels and comes to rest on it" do
    boot("terrain-drive")
    sleep 1.0
    drive({ throttle: 1 }, 2.5)
    drive({ brake: 1 }, 1.5)
    sleep 0.5

    t = telemetry
    assert_operator t["z"], :>, 10.0, "did not drive down the slope"
    ground = height_at(t["x"], t["z"])
    assert_operator ground, :<, 7.0, "should have descended from the hilltop"
    assert_operator t["grounded"], :>, 0, "the wheels lost the heightfield"
    clearance = t["y"] - ground
    assert_operator clearance, :>, 0.2, "sank into the slope"
    assert_operator clearance, :<, 2.5, "floating above the slope"
  end

  # The one hazard in the whole design, asserted rather than read off the Rust: the ground
  # the wheels stand on is the ground that is drawn, on both triangles of every cell of
  # every tile, across both seams, and at hundreds of points besides. `other` is what the
  # opposite diagonal would have given, and the test insists it differs -- a survey that
  # could not tell the two apart would pass whatever Rapier did.
  test "the physics ground is the drawn ground, either side of every diagonal and across every seam" do
    boot("terrain-probe")

    survey = page.evaluate_script(<<~JS)
      (function () {
        const terrain = JSON.parse(document.querySelector('[data-arena-target="spec"]').textContent).arena.terrain
        const step = terrain.height_step
        const cells = terrain.height_n - 1
        const size = terrain.tile_size
        const points = []
        for (const tile of terrain.tiles) {
          const x0 = tile.tx * size, z0 = tile.tz * size
          for (let i = 0; i < cells; i++) for (let j = 0; j < cells; j++) {
            const x = x0 + j * step, z = z0 + i * step
            points.push([ x + step / 3, z + step / 3 ])         // inside the first triangle
            points.push([ x + 2 * step / 3, z + 2 * step / 3 ]) // inside the second
          }
        }
        // Both seams: on the line and a centimetre either side, every half metre -- with the
        // OTHER coordinate kept a quarter metre off the grid lines. Measured: a vertical ray
        // exactly on 28 of the 79 row lines, or 28 of the 79 column lines, returns no hit from
        // Rapier anywhere along that line (float32 rounding of the cell index in its
        // vertical-ray special case), while a centimetre off it hits. That is a raycast
        // quirk at a measure-zero set, not a disagreement about height, and a car's wheel
        // rays are neither exactly vertical on a slope nor exactly on a grid line.
        for (let s = -199.75; s < 200; s += 0.5) {
          for (const d of [ -0.01, 0, 0.01 ]) { points.push([ d, s ]); points.push([ s, d ]) }
        }
        // A deterministic scatter, so a rerun sees the same points.
        let seed = 12345
        const next = () => (seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648
        for (let k = 0; k < 500; k++) points.push([ -199 + next() * 398, -199 + next() * 398 ])

        let count = 0, misses = 0, maxDelta = 0, maxTeeth = 0, maxSampled = 0, worst = null
        for (const [ x, z ] of points) {
          const p = window.__arenaTerrainProbe(x, z)
          if (!p || p.physics === null || p.render === null) { misses++; continue }
          count++
          const d = Math.abs(p.delta)
          if (d > maxDelta) { maxDelta = d; worst = { x, z, ...p } }
          maxTeeth = Math.max(maxTeeth, Math.abs(p.other - p.render))
          maxSampled = Math.max(maxSampled, Math.abs(p.sampled - p.render))
        }
        return { count, misses, maxDelta, maxTeeth, maxSampled, worst }
      })()
    JS

    assert_equal 0, survey["misses"], "some probes found no ground"
    assert_operator survey["count"], :>, 15_000
    assert_operator survey["maxDelta"], :<, 1e-3, "physics and render disagree: #{survey['worst'].inspect}"
    assert_operator survey["maxSampled"], :<, 1e-3, "the sampler disagrees with the drawn triangles"
    assert_operator survey["maxTeeth"], :>, 0.02, "the other diagonal never differed, so this proves nothing"
  end

  # Two ground-floor walls, which is what it takes to lose a storey. Damage rather than
  # break, so the report reaches the server and a collapse is actually decided.
  def wreck_ground_floor(building)
    page.execute_script(<<~JS, building)
      const id = arguments[0]
      const spec = window.__arenaBuildingSpec(id)
      const walls = spec.surfaces.filter(s => s.kind === "wall" && s.storey === 0)
      for (const s of walls.slice(0, 2)) {
        for (let i = s.off; i < s.off + s.cols * s.rows; i++) window.__arenaDamagePiece(i, 5000, id)
      }
    JS
  end

  # The house stands on a slope and its wreckage has to lie on that slope, not on a plane
  # at the height the house was built at. Every standing heap reports the ground it was
  # placed on; that ground has to be the terrain under it, and across the site those
  # grounds have to actually differ -- on a level site this test would prove nothing.
  test "a house on a slope leaves its wreckage on the slope" do
    boot("terrain-rubble")
    building = page.evaluate_script("window.__arenaBuildingIds()[0]")
    wreck_ground_floor(building)

    wait_for(timeout: 25, message: "the house never finished coming down") do
      page.evaluate_script("window.__arenaFalling()").zero? &&
        page.evaluate_script("window.__arenaRubble().dormant").zero?
    end

    heaps = page.evaluate_script(<<~JS, building)
      (function (id) {
        const s = window.__arenaBuildingSpec(id).surfaces.find(x => x.kind === "rubble")
        const out = []
        for (let i = s.off; i < s.off + s.cols * s.rows; i++) {
          if (!window.__arenaPieceState(i, id).standing) continue
          const g = window.__arenaHeapGround(i, id)
          out.push([ g.ground, window.__arenaTerrainHeight(g.x, g.z) ])
        }
        return out
      })(arguments[0])
    JS

    assert_operator heaps.length, :>, 10, "the house left almost nothing"
    heaps.each { |ground, terrain| assert_in_delta terrain, ground, 1e-3 }
    grounds = heaps.map(&:first)
    assert_operator grounds.max - grounds.min, :>, 0.3, "the site is level; this proves nothing"
  end
end
