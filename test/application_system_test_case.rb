require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  # These drive a real browser and assert on physics timing -- how far the car travelled
  # in two seconds, what the frame rate held. Several Chrome instances competing for CPU
  # starves the render loop and turns those measurements into noise, so system tests run
  # serially even though the model tests parallelise fine.
  parallelize(workers: 1)

  # That reasoning does not stop at the edge of this checkout. Several agents work this
  # repo at once in parallel worktrees, and two suites running concurrently starve each
  # other's render loop exactly as two workers would -- except the failures surface as
  # flaky physics assertions rather than as anything that looks like contention. The lock
  # lives outside every worktree, so whichever checkout starts first holds it and the rest
  # queue behind it.
  SYSTEM_TEST_LOCK = File.join(Dir.home, ".carnavalskraker", "system-tests.lock")

  def self.acquire_machine_lock
    FileUtils.mkdir_p(File.dirname(SYSTEM_TEST_LOCK))
    lock = File.open(SYSTEM_TEST_LOCK, File::CREAT | File::RDWR, 0o644)

    unless lock.flock(File::LOCK_EX | File::LOCK_NB)
      puts "== Waiting for the system-test lock (another worktree is running the suite) =="
      lock.flock(File::LOCK_EX)
    end

    # Held for the life of the process. The File must stay referenced: letting it be
    # collected closes the descriptor, which releases the lock while the suite runs on.
    @machine_lock = lock
  end

  # The lock only keeps other suites away. A dev server left running in this worktree
  # steals CPU just as effectively, and the physics assertions fail in the same
  # hard-to-read way -- so say so rather than letting it look like a real regression.
  def self.warn_about_dev_server
    port = Rails.root.join(".dev-port")
    return unless port.exist?

    running = system("lsof", "-ti", ":#{port.read.strip}", out: File::NULL, err: File::NULL)
    return unless running

    puts "== A dev server is running on port #{port.read.strip}. Physics timings will be noisy. =="
  end

  acquire_machine_lock
  warn_about_dev_server

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

  # Every test says which world it needs. A test about steering wants flat ground and
  # nothing else; one about the bull bar wants something to hit. Booting a whole city to
  # measure how fast a car accelerates is slow, and worse, it means measuring on whatever
  # ground that city happened to put underneath -- which is how acceleration and braking
  # ended up being timed on a cambered, kerbed corner.
  def visit_world(slug, vehicle: nil)
    visit root_path(params: { world: slug, vehicle: vehicle }.compact)
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
