require "application_system_test_case"

# Driving THROUGH a hedge, measured.
#
# "A hedge you cannot drive through is the one thing this game must not have" is the
# design's one non-negotiable, and until this file the only evidence for it was 0.42 hp a
# cell and a toll of 0.05 -- two numbers that say a hedge is easy to BREAK and nothing at
# all about whether the car ever reaches one. The wheels are raycasts, so whatever they
# land on is the ground: `groups.js` records a truck riding up a pile of wreckage on its
# own suspension rays, parking on the mound with its blade reading nought, and clearing
# nothing. A hedge is a metre tall and half a metre thick, and it sits on LAYER.PROP with
# the walls, which is to say the wheels can see it.
#
# So this drives at one and measures three things: that the leaves came off, that the car
# did not slow as if it had hit masonry, and that it is on the ground on the far side
# rather than on top of what it was supposed to go through. The clearance is measured
# against the car's OWN resting height rather than a guess, because a car balanced on a
# one-metre hedge is only a metre up and a fixed band generous enough for the truck would
# pass it.
#
# MEASURED, on estate-row-17, before anything was changed: in at 9.67 m/s, never below
# 10.29 through the hedge -- the buggy is still ACCELERATING as it goes through -- all
# three of the aimed cells cleared, and the clearance out (0.79 m) the same to the
# centimetre as the clearance in. It does not climb, so the wheel rays need no exemption
# and LAYER.HEDGE was not added. The reason is geometry rather than luck: a hedge stands a
# metre tall and the buggy's chassis box hangs well below that, so the chassis reaches the
# cells before a wheel is ever over them and 0.42 hp a cell goes on the first touch. What
# the rubble rule fixed was a pile the wheel rays could reach BEFORE the blade could, which
# is a shape a hedge does not have.
class HedgesTest < ApplicationSystemTestCase
  # Metres of run-up. Enough for the buggy to be at speed, short enough to stay on the
  # road the garden faces rather than in the terrace opposite.
  RUN_UP = 8.0
  # How far from any OTHER building the run-up has to start. A car parked in somebody's
  # front room measures being ejected from it.
  CLEAR = 6.0
  # How far past the hedge's plane counts as through, and how much room the dwelling
  # behind it has to leave for that: the buggy's nose reaches about two metres ahead of
  # the point telemetry reports, and hitting the front wall would end the measurement with
  # a number that is about brick.
  THROUGH = 1.5
  GARDEN = 4.5
  # The ceiling on the drive, in simulation steps. The normal exit is being through.
  STEPS = 600
  # A few simulated seconds: parked, the buggy drops 1.5 m onto its wheels and settles.
  # Simulated, not wall -- see `wait_for_simulated`'s own comment for why geleen needs that.
  SETTLE_BUDGET = 5
  # Twice STEPS' own ceiling, converted to simulated seconds -- a generous backstop. STEPS
  # is the real cap: the block below returns the moment it is reached, budget or no.
  DRIVE_BUDGET = STEPS / Game::Spec::PHYSICS_HZ.to_f * 2

  def boot(match:)
    visit_world("geleen", vehicle: "buggy", quality: "low", match: match, spawn: 0)
    wait_for(timeout: 60, message: "geleen never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
    # `ready` is the engine having booted, not the WORLD having run: Rapier builds its
    # broad phase inside `step`, so everything below -- the placement, the raycasts under
    # the wheels -- needs the world to have stepped at least once.
    wait_for(timeout: 60, message: "the world never stepped") { page.evaluate_script("window.__arena.steps").positive? }
  end

  def telemetry = page.evaluate_script("window.__arena")

  def height_at(x, z) = page.evaluate_script("window.__arenaTerrainHeight(arguments[0], arguments[1])", x, z)

  teardown { page.execute_script("window.__arenaInput = null") }

  test "a buggy drives through a front hedge without slowing or climbing it" do
    boot(match: "geleen-hedges")
    target = pick_a_hedge
    assert target, "no dwelling on the estate has a hedge with a clear run-up"

    resting = clearance(park(target))

    samples = drive_through(target)
    before = samples.reverse.find { |s| s["broken"].zero? }
    through = samples.select { |s| s["broken"].positive? }
    last = samples.last

    assert before, "the car was already in the hedge before it set off"
    assert_operator last["broken"], :>=, 3,
                    "#{target['name']} lost #{last['broken']} of the #{target['run']} hedge cells it was aimed at"
    refute_empty through, "the hedge broke and the car never got a reading through it"

    # The speed floor. A hedge is leaves: `toll` is 0.05 against a wall's 1.0, so going
    # through one should cost a fraction of the speed going in. Sixty per cent is loose
    # enough not to measure the road's camber and tight enough that a car climbing the
    # hedge -- which stalls it -- fails.
    speed_in = before["speed"]
    slowest = through.map { |s| s["speed"] }.min
    assert_operator speed_in, :>, 5.0, "the buggy never got up to speed in #{RUN_UP} m of road"
    assert_operator slowest, :>, speed_in * 0.6,
                    "in at #{speed_in.round(1)} m/s, down to #{slowest.round(1)} through the hedge"

    # And out the other side on the road. Against the car's own resting clearance, because
    # a buggy standing on a one-metre hedge is a metre up and no more.
    assert_operator last["past"], :>, 0, "the car never reached the far side"
    # The MAXIMUM over every sample once the hedge started breaking, not the last: a car
    # that rode up and dropped back off the far side before the final reading would pass a
    # last-sample check despite having climbed it.
    peak = through.map { |s| clearance(s) }.max
    assert_operator peak, :<, resting + 0.8,
                    "the car reached #{(peak - resting).round(2)} m higher than it went in: it climbed the hedge"
    assert_operator clearance(last), :>, 0.1, "the car sank into the ground"
    assert_empty page.evaluate_script("window.__arenaNetErrors()")
  end

  private
    def clearance(t) = t["y"] - height_at(t["x"], t["z"])

    # A hedge to drive at, and where to drive at it from.
    #
    # Aimed at the middle of the longest unbroken RUN of hedge, never the middle of the
    # surface: the garden path is void cells punched through the hedge to reach the door,
    # and a car aimed at the middle of a five-cell hedge with a two-cell path in it drives
    # between the leaves and breaks nothing, which would pass every assertion here by
    # never testing any of them.
    def pick_a_hedge
      page.evaluate_script(<<~JS)
        (() => {
          const ids = window.__arenaBuildingIds()
          // Every building's surface corners in world xz: a cheap point cloud, enough to
          // keep the run-up out of the terrace across the road.
          const cloud = new Map()
          for (const id of ids) {
            const spec = window.__arenaBuildingSpec(id)
            if (!spec) continue
            const points = []
            for (const s of spec.surfaces) {
              for (const [ a, b ] of [ [ 0, 0 ], [ 1, 0 ], [ 0, 1 ], [ 1, 1 ] ]) {
                points.push([ spec.o[0] + s.o[0] + s.u[0] * s.w * a + s.v[0] * s.h * b,
                              spec.o[2] + s.o[2] + s.u[2] * s.w * a + s.v[2] * s.h * b ])
              }
            }
            cloud.set(id, points)
          }

          for (const id of ids) {
            const spec = window.__arenaBuildingSpec(id)
            if (!spec || spec.category !== "house") continue
            for (const hedge of spec.surfaces.filter((s) => s.kind === "hedge")) {
              const cells = hedge.cols * hedge.rows
              // The longest run of cells that are actually leaves.
              let run = { from: 0, length: 0 }
              let start = null
              for (let c = 0; c <= hedge.cols; c += 1) {
                const leaves = c < hedge.cols && window.__arenaPieceState(hedge.off + c, id).material !== "void"
                if (leaves && start === null) start = c
                if (!leaves && start !== null) {
                  if (c - start > run.length) run = { from: start, length: c - start }
                  start = null
                }
              }
              if (run.length < 3) continue

              const along = (run.from + run.length / 2) * (hedge.w / hedge.cols)
              const cx = spec.o[0] + hedge.o[0] + hedge.u[0] * along
              const cz = spec.o[2] + hedge.o[2] + hedge.u[2] * along
              // Across the hedge and away from the house it fronts. `n` is u x v and
              // points back at the dwelling, but that is asserted rather than assumed:
              // the row's own origin lies on the house side of its gardens, so the street
              // is whichever of the two candidates stands FARTHER from it.
              let dx = -hedge.n[0]
              let dz = -hedge.n[2]
              const length = Math.hypot(dx, dz) || 1
              dx /= length
              dz /= length
              const away = (sx, sz) => Math.hypot(spec.o[0] - sx, spec.o[2] - sz)
              if (away(cx + dx * #{RUN_UP}, cz + dz * #{RUN_UP}) < away(cx - dx * #{RUN_UP}, cz - dz * #{RUN_UP})) {
                dx = -dx
                dz = -dz
              }
              const sx = cx + dx * #{RUN_UP}
              const sz = cz + dz * #{RUN_UP}

              // Room to stop in on the far side: the dwelling's own walls have to stand
              // clear of the hedge, or the measurement ends against brick.
              const ahead = cloud.get(id)
                .map((p) => (p[0] - cx) * -dx + (p[1] - cz) * -dz)
                .filter((d) => d > 0.5)
              if (ahead.length === 0 || Math.min(...ahead) < #{GARDEN}) continue

              // And nobody else's house in the run-up.
              let clear = true
              for (const [ other, points ] of cloud) {
                if (other === id) continue
                if (points.some((p) => Math.hypot(p[0] - sx, p[1] - sz) < #{CLEAR})) { clear = false; break }
              }
              if (!clear) continue

              return {
                id: id, name: spec.name, cells: cells, run: run.length,
                from: [ sx, sz ], at: [ cx, cz ], toward: [ -dx, -dz ],
                // Forward is +Z turned by yaw, so this is the heading that points at the
                // hedge. vehicle.js says so at the one place the convention lives.
                yaw: Math.atan2(-dx, -dz),
                first: hedge.off, last: hedge.off + cells - 1
              }
            }
          }
          return null
        })()
      JS
    end

    # On the road, facing the hedge, and left alone long enough to settle onto its wheels.
    # `y` is above the GROUND: the estate stands five metres up.
    def park(target)
      x, z = target["from"]
      ground = height_at(x, z) || 0.0
      page.execute_script("window.__arenaPlace = { x: #{x}, y: #{ground + 1.5}, z: #{z}, yaw: #{target['yaw']} }")
      # Returns the settled reading rather than a second round trip for it: the car is
      # only known to be still for as long as the assertion that found it still.
      wait_for_simulated(SETTLE_BUDGET, message: "the buggy never settled on the road") do
        t = telemetry
        t if t["grounded"] == 4 && t["speed"] < 0.5
      end
    end

    # Throttle down until the car is through, sampling as it goes. Sampled from Ruby
    # rather than measured at the end, because what is being measured is the speed WHILE
    # it is in the hedge -- a car that stalls against one and is nudged through by the
    # accumulator arrives with a perfectly good final speed.
    #
    # The wait is simulated, not wall: STEPS is still the real ceiling, checked on every
    # sample, and `wait_for_simulated`'s stall detector stands in for what used to be a
    # 240-wall-second deadline -- geleen can run this drive slowly under load and still be
    # healthy, which a wall clock cannot tell apart from having actually stopped.
    def drive_through(target)
      from = page.evaluate_script("window.__arena.steps")
      samples = [ sample(target) ]
      page.execute_script("window.__arenaInput = { throttle: 1 }")

      wait_for_simulated(DRIVE_BUDGET, message: "the car never got through the hedge") do
        s = sample(target)
        samples << s
        s["past"] > THROUGH || s["steps"] - from >= STEPS
      end
      samples
    ensure
      page.execute_script("window.__arenaInput = null")
    end

    # One round trip: where the car is, how fast, how far past the hedge's plane it has
    # travelled, and how much of the hedge is gone.
    def sample(target)
      page.evaluate_script(<<~JS)
        (() => {
          const a = window.__arena
          let broken = 0
          for (let i = #{target['first']}; i <= #{target['last']}; i += 1) {
            const s = window.__arenaPieceState(i, #{target['id']})
            if (s && s.material !== "void" && !s.standing) broken += 1
          }
          return {
            steps: a.steps, speed: a.speed, x: a.x, y: a.y, z: a.z, grounded: a.grounded, broken: broken,
            past: (a.x - #{target['at'][0]}) * #{target['toward'][0]} + (a.z - #{target['at'][1]}) * #{target['toward'][1]}
          }
        })()
      JS
    end
end
