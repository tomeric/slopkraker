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

  private
    # A row is generated in a frame of its own -- local x along the terrace, local z
    # across it, the street at z = 0 -- and then set down at `o` and turned by `yaw`. So
    # "stand in front of it" is a point in THAT frame carried out to the world, and the
    # car has to be turned back down the local +z axis or it photographs the far side of
    # the road.
    def park_in_front_of(id, back:)
      spec = page.evaluate_script("window.__arenaBuildingSpec(arguments[0])", id)
      ring = WorldObject.find(id).recipe.fetch("footprint")
      lx = (ring.map(&:first).min + ring.map(&:first).max) / 2.0
      lz = -back
      ox, _, oz = spec.fetch("o")
      yaw = spec.fetch("yaw")

      park(ox + lx * Math.cos(yaw) - lz * Math.sin(yaw),
           oz + lx * Math.sin(yaw) + lz * Math.cos(yaw),
           yaw: Math.atan2(-Math.sin(yaw), Math.cos(yaw)))
    end

    def press(key)
      page.driver.browser.action.key_down(key).key_up(key).perform
      sleep 0.3
    end

    # `y` is a height above the GROUND, not above zero: on a world with terrain, parking
    # at a fixed 2.0 puts the car underneath the hill it was meant to be photographing
    # from. Flat worlds answer null and keep the height they always had.
    def park(x, z, yaw: 0, y: 2.0)
      ground = page.evaluate_script("window.__arenaTerrainHeight(arguments[0], arguments[1])", x, z) || 0.0
      page.execute_script("window.__arenaPlace = { x: #{x}, y: #{ground + y}, z: #{z}, yaw: #{yaw} }")
      sleep 1.2
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
