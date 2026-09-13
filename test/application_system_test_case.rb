require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  # These drive a real browser and assert on physics timing -- how far the car travelled
  # in two seconds, what the frame rate held. Several Chrome instances competing for CPU
  # starves the render loop and turns those measurements into noise, so system tests run
  # serially even though the model tests parallelise fine.
  parallelize(workers: 1)

  # Headless Chrome has no GPU, so WebGL needs SwiftShader explicitly or the canvas
  # silently fails to acquire a context and the engine never boots.
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 900 ] do |options|
    options.add_argument("--enable-unsafe-swiftshader")
    options.add_argument("--use-angle=swiftshader")
    # Audio is exercised for real in these tests (oscillators, noise, the lot). Muting at
    # the browser level keeps automated runs silent on whoever's machine they run on,
    # while leaving the Web Audio graph -- and therefore the assertions -- untouched.
    options.add_argument("--mute-audio")
    options.add_argument("--autoplay-policy=no-user-gesture-required")
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
  end

  # Selenium keeps one browser session across tests, so a test that fails while holding a
  # key leaves it held for every test that follows -- which shows up much later as an
  # unrelated flake. Reset input state after every test.
  teardown do
    begin
      page.driver.browser.action.release_actions
    rescue StandardError
      nil
    end
    begin
      page.execute_script("window.__arenaInput = null; navigator.getGamepads = () => []")
    rescue StandardError
      nil
    end
  end

  # Capybara does not retry evaluate_script, so poll for engine milestones.
  def wait_for(timeout: 20, message: "condition never met")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      result = yield
      return result if result
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        # A silent timeout is almost always a thrown exception during boot; surface it.
        errors = severe_console_errors
        flunk([ message, *errors ].join("\n  "))
      end
      sleep 0.25
    end
  end

  def severe_console_errors
    page.driver.browser.logs.get(:browser)
      .select { |entry| entry.level == "SEVERE" }
      .map(&:message)
  end
end
