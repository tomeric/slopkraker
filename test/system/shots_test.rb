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

  private
    def press(key)
      page.driver.browser.action.key_down(key).key_up(key).perform
      sleep 0.3
    end

    def park(x, z, yaw: 0)
      page.execute_script("window.__arenaPlace = { x: #{x}, y: 2.0, z: #{z}, yaw: #{yaw} }")
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
