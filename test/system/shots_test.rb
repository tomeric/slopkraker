require "application_system_test_case"

# Not a test. A way of looking at the house from somewhere other than the machine it is
# running on: boots the world, puts the car where something is worth seeing, and saves a
# frame. Run it by name, never as part of the suite.
class ShotsTest < ApplicationSystemTestCase
  SHOTS = Rails.root.join("tmp/shots")

  # Opt in with SHOTS=1. It is slow, it takes no position on whether anything is correct,
  # and left to itself it would re-photograph the house on every suite run.
  test "photograph the house" do
    skip "set SHOTS=1 to take screenshots" unless ENV["SHOTS"]

    FileUtils.mkdir_p(SHOTS)
    visit_world("targets", vehicle: "buggy", quality: "high")
    wait_for(message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
    sleep 1.5

    # G drops the debug gizmos, H the controls panel. Both sit squarely over the thing
    # worth photographing.
    press("g")
    press("h")
    sleep 0.6

    # The house stands at world x 20..32, z 8..23. Yaw 0 faces +z, so anything parked
    # south of it on the x = 26 line is looking straight at its front.
    park(26, -22)
    shot "01-house"

    park(26, 3)
    shot "02-wall-close"

    # Along the face rather than at it, which is where the running bond and the jitter
    # actually show.
    park(15, 12, yaw: Math::PI / 2)
    shot "03-bond-raking"

    drive_into_the_wall
    park(26, -4)
    shot "04-driven-through"

    fire_a_rocket(wait: 0.55)
    shot "05-rocket-going-off"

    # Let the shell finish expanding and fade before looking at what it left.
    sleep 3.0
    park(26, -7)
    shot "06-hole"

    park(20, 6, yaw: Math::PI / 2)
    shot "07-interior"

    puts "\n--- shots in #{SHOTS}"
    Dir.children(SHOTS).sort.each { |f| puts "      #{f}" }
  end

  # The wreckage, for judging by eye what no number settles: whether the pile a house
  # leaves is the size of the house. Brings the targets house down through the piece
  # hooks, waits for the dust, and photographs the pile from the front, the diagonal and
  # the side, then drives the truck through it and photographs that.
  test "photograph the wreckage" do
    skip "set SHOTS=1 to take screenshots" unless ENV["SHOTS"]

    FileUtils.mkdir_p(SHOTS)
    visit_world("targets", vehicle: "monster_truck", quality: "high", match: "shots-wreckage")
    wait_for(message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
    sleep 1.5
    press("g")
    press("h")
    sleep 0.6

    building = page.evaluate_script("window.__arenaBuildingIds()[0]")
    page.execute_script(<<~JS, building)
      const id = arguments[0]
      const spec = window.__arenaBuildingSpec(id)
      const walls = spec.surfaces.filter(s => s.kind === "wall" && s.storey === 0)
      for (const s of walls.slice(0, 2)) {
        for (let i = s.off; i < s.off + s.cols * s.rows; i++) window.__arenaDamagePiece(i, 5000, id)
      }
    JS
    park(26, -12)
    sleep 1.2
    shot "10-coming-down"
    wait_for(timeout: 25, message: "the house never came down") do
      page.evaluate_script("window.__arenaFalling() === 0 && window.__arenaRubble().dormant === 0")
    end
    sleep 1.0

    # The pile now skirts the walls by two metres, so it runs from about z = 6 to 25.
    park(26, -12)
    shot "11-wreckage-front"
    park(8, -6, yaw: 0.72)
    shot "12-wreckage-diagonal"
    park(4, 15.5, yaw: Math::PI / 2)
    shot "13-wreckage-side"

    # Close, from the road, which is where a driver actually sees a pile from and where
    # the flat sides of the old lumps showed.
    park(26, 1.5)
    shot "13b-edge-close"
    park(15, -1, yaw: 0.35)
    shot "13c-along-the-edge"

    # Through it. From z = -16 at full throttle the truck is in the thick of the pile at
    # about three and a half seconds and coming out of it a second later.
    park(26, -16)
    page.execute_script("window.__arenaInput = { throttle: 1 }")
    sleep 3.6
    shot "14-ploughing"
    sleep 0.9
    shot "15-ploughing-out"
    page.execute_script("window.__arenaInput = null")
    sleep 1.5
    park(26, -12)
    shot "16-the-path-it-cleared"

    puts "\n--- shots in #{SHOTS}"
    Dir.children(SHOTS).sort.each { |f| puts "      #{f}" }
  end

  # The imported world from the driver's seat, which is the only place the question
  # settles: does a terrace of four real dwellings on real ground read as a street, and
  # is the church the size of a church. Both are framed from the building's OWN frame
  # rather than from a world offset, because every row stands at its survey bearing.
  test "photograph geleen" do
    skip "set SHOTS=1 to take screenshots" unless ENV["SHOTS"]

    FileUtils.mkdir_p(SHOTS)
    visit_world("geleen", vehicle: "buggy", quality: "high", match: "shots-geleen")
    wait_for(timeout: 120, message: "geleen never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
    wait_for(timeout: 120, message: "the world never stepped") { page.evaluate_script("window.__arena.steps").positive? }
    sleep 2.0
    press("g")
    press("h")
    sleep 0.6

    # A terrace of four on the ESTATE. The church island has one too, but it is hemmed in
    # by its neighbours, and a chase camera eight metres back from a building there stands
    # inside the building behind -- which photographs a terrace through somebody's window.
    row = page.evaluate_script(<<~JS)
      window.__arenaBuildingIds().find(i => {
        const s = window.__arenaBuildingSpec(i)
        if (s.category !== "house" || !s.name.startsWith("estate-")) return false
        const walls = s.surfaces.filter(x => x.kind === "wall")
        const bays = new Set(walls.filter(x => !x.between).map(x => x.bay ?? 0))
        return bays.size >= 4 && walls.some(x => x.between)
      })
    JS
    park_in_front_of(row, back: 8)
    shot "20-geleen-row-from-the-kerb"

    church = page.evaluate_script("window.__arenaBuildingIds().find(i => window.__arenaBuildingSpec(i).category === 'church')")
    park_in_front_of(church, back: 25)
    shot "21-geleen-church"

    # Close, which is where brick reads as brick or does not: three metres off a front.
    park_in_front_of(row, back: 3)
    shot "22-geleen-wall-at-three-metres"

    # A gable end from the side, where the stair used to show.
    park_beside(row, side: 1, out: 9)
    shot "25-geleen-gable-end"

    # From above the kerb, where a roof is actually visible: the panels, the chimneys and
    # the gutter line all live up there and none of them shows from the driver's seat.
    park_in_front_of(row, back: 14, y: 9.0, hold: true)
    shot "27-geleen-roofs"

    # The back of a glazed dwelling, from its back garden. Finds the WALL, not just the
    # building: without the category check this found estate-shed-18 first -- a shed with
    # its own, unrelated floor-to-ceiling glass patch -- because a shed's name also starts
    # with "estate-" and `find` takes whichever comes first (confirmed by dumping the
    # resolved id from inside the actual test run: category was "shed", not "house").
    #
    # Parking off the footprint's bounding box does not work here even once the right
    # dwelling is found: this estate's plots are irregular L-shapes with rear extensions,
    # so "past the footprint's deepest point" can stand hard against a RETURN wall at a
    # right angle to the glazing rather than in the garden it looks onto -- confirmed live,
    # the camera grazing a wall a hand's width away with the glazing out of frame, at a
    # position that was nonetheless outside every building's footprint. So this parks off
    # the glazed WALL's own normal instead. `o`/`n`/`u` on a surface are already rotated
    # into world orientation server-side (Surface#rotated); only the building's own
    # translation remains to add. Which sign of `n` points into the garden rather than back
    # through the house is not documented anywhere and is not safe to assume -- confirmed
    # live the OTHER way round too, standing inside the dwelling's own footprint -- so both
    # signs are tried against the dwelling's own footprint (the same recipe/o/yaw every
    # other helper here uses) and whichever lands outside it is the one used.
    wall = page.evaluate_script(<<~JS)
      (() => {
        for (const i of window.__arenaBuildingIds()) {
          const s = window.__arenaBuildingSpec(i)
          if (s.category !== "house" || !s.name.startsWith("estate-")) continue
          const surf = s.surfaces.find(x => x.kind === "wall" && x.patches.some(p => p[4] === "glass" && p[1] === 0 && p[3] === x.rows - 1))
          if (surf) return { id: i, o: s.o, yaw: s.yaw, surf }
        }
        return null
      })()
    JS
    park_off_wall(wall, back: 8) if wall
    shot "26-geleen-glass-back" if wall

    # A garage, if the import found one on the estate.
    garage = page.evaluate_script("window.__arenaBuildingIds().find(i => window.__arenaBuildingSpec(i).lawns && window.__arenaBuildingSpec(i).lawns.length > 0 && window.__arenaBuildingSpec(i).name.startsWith('estate-'))")
    park_in_front_of(garage, back: 10) if garage
    shot "23-geleen-garden-and-hedge" if garage

    # The same kerb, at night, for the comparison the default was chosen against.
    visit_world("geleen", vehicle: "buggy", quality: "high", match: "shots-geleen-night", time: "night")
    wait_for(timeout: 120, message: "geleen never booted at night") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
    wait_for(timeout: 120, message: "the world never stepped") { page.evaluate_script("window.__arena.steps").positive? }
    sleep 2.0
    press("g")
    press("h")
    park_in_front_of(row, back: 8)
    shot "24-geleen-row-at-night"

    puts "\n--- shots in #{SHOTS}"
    Dir.children(SHOTS).sort.each { |f| puts "      #{f}" }
  end

  # The roofs above, and the one shot that has to pick its row by what is ON it rather
  # than by how long it is. "27-geleen-roofs" photographs a terrace of four, and every
  # row on this estate carrying TWO stacks is a PAIR -- so the shot meant for looking at
  # chimneys could not see the four rows that stood theirs 0.95 m apart, reading as one
  # fat double stack. A pair is also the only shape where the rule has anything to prove:
  # two dwellings are one party line and one end wall, which is both cases at once.
  test "photograph a pair of stacks" do
    skip "set SHOTS=1 to take screenshots" unless ENV["SHOTS"]

    FileUtils.mkdir_p(SHOTS)
    visit_world("geleen", vehicle: "buggy", quality: "high", match: "shots-geleen-stacks")
    wait_for(timeout: 120, message: "geleen never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
    wait_for(timeout: 120, message: "the world never stepped") { page.evaluate_script("window.__arena.steps").positive? }
    sleep 2.0
    press("g")
    press("h")
    sleep 0.6

    # Asked of the generator rather than of the flags: a dwelling can be flagged for a
    # chimney and still build none (a flat roof, or one narrower than its own stack).
    pair = World.find_by!(slug: "geleen").world_objects.where(kind: "building").find do |o|
      next false unless o.recipe["kind"] == "row"
      row = Game::Building::Row.from(o.recipe)
      row.dwellings.each_with_index.count { |d, i| Game::Building::RowGenerator.chimney(row, d, i).any? } >= 2
    end
    assert pair, "no row on geleen builds two stacks -- has the seed stopped flagging chimneys?"
    puts "--- two stacks on #{pair.name}"

    # From above the kerb: both stacks in one frame, which is the whole question.
    park_in_front_of(pair.id, back: 16, y: 11.0, hold: true)
    shot "28-geleen-paired-stacks"

    # And at the far corner, where the last dwelling's stack now stands astride the gable
    # and 50 mm proud of the verge -- the one thing here that no measurement settles.
    # Square off the end (`park_beside`) does not work on this row: confirmed live, the
    # frame was the return wall of the plot next door at arm's length, which is the same
    # irregular-plot trap `park_off_wall` exists for. From the street off the corner the
    # gable and the front are both in shot, which is what puts the stack on a roof.
    park_at_corner(pair, back: 13, along: 9, y: 8.0)
    shot "29-geleen-end-stack-on-the-gable"

    puts "\n--- shots in #{SHOTS}"
    Dir.children(SHOTS).sort.each { |f| puts "      #{f}" }
  end

  private
    # A row is generated in a frame of its own -- local x along the terrace, local z
    # across it, the street at z = 0 -- and then set down at `o` and turned by `yaw`. So
    # "stand in front of it" is a point in THAT frame carried out to the world, and the
    # car has to be turned back down the local +z axis or it photographs the far side of
    # the road.
    def park_in_front_of(id, back:, y: 2.0, hold: false)
      spec = page.evaluate_script("window.__arenaBuildingSpec(arguments[0])", id)
      ring = WorldObject.find(id).recipe.fetch("footprint")
      lx = (ring.map(&:first).min + ring.map(&:first).max) / 2.0
      lz = -back
      ox, _, oz = spec.fetch("o")
      yaw = spec.fetch("yaw")

      park(ox + lx * Math.cos(yaw) - lz * Math.sin(yaw),
           oz + lx * Math.sin(yaw) + lz * Math.cos(yaw),
           yaw: Math.atan2(-Math.sin(yaw), Math.cos(yaw)), y: y, hold: hold)
    end

    # Out in the street and past the row's far end, looking diagonally back into the
    # corner where the gable meets the front. The local heading is the same convention
    # park_beside uses -- world yaw is -(row yaw + local angle), with local +z at 0 and
    # the angle running toward local -x -- so a quarter turn between the two is pi / 4.
    def park_at_corner(object, back:, along:, y:)
      spec = page.evaluate_script("window.__arenaBuildingSpec(arguments[0])", object.id)
      ring = object.recipe.fetch("footprint")
      lx = ring.map(&:first).max + along
      lz = -back
      ox, _, oz = spec.fetch("o")
      yaw = spec.fetch("yaw")

      park(ox + lx * Math.cos(yaw) - lz * Math.sin(yaw),
           oz + lx * Math.sin(yaw) + lz * Math.cos(yaw),
           yaw: -(yaw + Math::PI / 4), y: y, hold: true)
    end

    # Beside a row, off one end, looking along it at its gable end.
    def park_beside(id, side:, out:)
      spec = page.evaluate_script("window.__arenaBuildingSpec(arguments[0])", id)
      ring = WorldObject.find(id).recipe.fetch("footprint")
      lx = side.positive? ? ring.map(&:first).max + out : ring.map(&:first).min - out
      lz = (ring.map(&:last).min + ring.map(&:last).max) / 2.0
      ox, _, oz = spec.fetch("o")
      yaw = spec.fetch("yaw")
      # The first guess (`yaw + facing + Math::PI`) faced along the row instead of at its
      # end -- confirmed live on estate-row-9 (yaw -2.3323 rad), which put the camera
      # looking down the street with the terrace off to one side. Negating the whole sum
      # instead -- `-(yaw + facing)` -- is what `park_in_front_of` already does to turn a
      # LOCAL direction into a world yaw (its `atan2(-sin, cos)` is the same negation for
      # facing local +z); the gable end only swaps which local axis the camera faces.
      facing = side.positive? ? Math::PI / 2 : -Math::PI / 2
      park(ox + lx * Math.cos(yaw) - lz * Math.sin(yaw), oz + lx * Math.sin(yaw) + lz * Math.cos(yaw), yaw: -(yaw + facing))
    end

    # Off a specific WALL's own normal rather than the building's bounding box -- see the
    # comment at the call site for why a bounding box cannot stand in for this on a plot
    # this irregular. `wall` is `{ id, o: <building o>, surf: <surface spec> }`; `surf.o`,
    # `.n` and `.u` are already rotated into world orientation (Surface#rotated), so only
    # the building's own translation is added, never its yaw.
    def park_off_wall(wall, back:)
      bx, _, bz = wall.fetch("o")
      surf = wall.fetch("surf")
      ox, _, oz = surf.fetch("o")
      nx, _, nz = surf.fetch("n")
      ux, _, uz = surf.fetch("u")
      width = surf.fetch("w")
      cx = bx + ox + ux * width / 2
      cz = bz + oz + uz * width / 2

      ring = WorldObject.find(wall.fetch("id")).recipe.fetch("footprint")
      byaw = wall.fetch("yaw")
      footprint = ring.map { |x, z| [ bx + x * Math.cos(byaw) - z * Math.sin(byaw), bz + x * Math.sin(byaw) + z * Math.cos(byaw) ] }
      sign = inside_ring?(footprint, cx + nx * back, cz + nz * back) ? -1 : 1

      park(cx + sign * nx * back, cz + sign * nz * back, yaw: Math.atan2(-sign * nx, -sign * nz))
    end

    # Even-odd ray casting, `ring` in the same (x, z) frame as the point.
    def inside_ring?(ring, x, z)
      inside = false
      j = ring.length - 1
      ring.each_with_index do |(xi, zi), i|
        xj, zj = ring[j]
        if (zi > z) != (zj > z) && x < (xj - xi) * (z - zi) / (zj - zi) + xi
          inside = !inside
        end
        j = i
      end
      inside
    end

    def press(key)
      page.driver.browser.action.key_down(key).key_up(key).perform
      sleep 0.3
    end

    # `y` is a height above the GROUND, not above zero: on a world with terrain, parking
    # at a fixed 2.0 puts the car underneath the hill it was meant to be photographing
    # from. Flat worlds answer null and keep the height they always had.
    # `hold` is for a pose ABOVE the ground, which is not a pose a car keeps. __arenaPlace is
    # a one-shot, so a car put nine metres up is in free fall by the time the shutter opens:
    # 1.2 s is about seven metres of it, and the frame then depends on whether the fall had
    # ended, bounced or rolled. Re-placing it ten times a second instead zeroes its velocity
    # each time (Vehicle#placeAt) and gives the chase camera a stationary car to settle
    # behind, so the same run takes the same picture.
    def park(x, z, yaw: 0, y: 2.0, hold: false)
      ground = page.evaluate_script("window.__arenaTerrainHeight(arguments[0], arguments[1])", x, z) || 0.0
      pose = "window.__arenaPlace = { x: #{x}, y: #{ground + y}, z: #{z}, yaw: #{yaw} }"
      unless hold
        page.execute_script(pose)
        return sleep 1.2
      end

      16.times do
        page.execute_script(pose)
        sleep 0.1
      end
    end

    # Twice, because one good hit opens a hole and the second one widens it into
    # something you can actually see into.
    def drive_into_the_wall
      2.times do
        park(26, -20)
        page.execute_script("window.__arenaInput = { throttle: 1 }")
        sleep 4.5
        page.execute_script("window.__arenaInput = null")
        sleep 0.8
      end
    end

    def fire_a_rocket(wait: 2.5)
      park(29, -3)
      page.execute_script("window.__arenaInput = { action: true, actionPressed: true }")
      sleep 0.3
      page.execute_script("window.__arenaInput = null")
      sleep wait
    end

    def shot(name)
      page.save_screenshot(SHOTS.join("#{name}.png").to_s)
    end
end
