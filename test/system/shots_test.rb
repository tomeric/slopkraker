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
