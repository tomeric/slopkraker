require "application_system_test_case"

# A gamepad is injected rather than required: navigator.getGamepads is overridden with a
# fake pad, which exercises the whole GamepadSource path without hardware.
#
# Xbox standard mapping: 0 A, 4 LB, 6 LT, 7 RT.
class GamepadTest < ApplicationSystemTestCase
  A = 0   # action
  LB = 4  # brake / reverse
  RB = 5  # turbo
  LT = 6  # slide
  RT = 7  # throttle

  setup do
    visit root_path
    wait_for(message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
    sleep 0.8
  end

  teardown { unplug }

  # Regression: stick_sensitivity was read from the gamepad bindings but lives on the
  # camera spec, so every camera axis went NaN the instant a stick moved. That poisons the
  # camera transform permanently and renders a black screen with nothing logged.
  test "moving the right stick keeps the camera finite" do
    plug(axes: [ 0, 0, 0.9, 0.4 ])
    sleep 1.0

    camera = telemetry["camRight"]
    assert camera.all? { |c| c.is_a?(Numeric) && c.to_f.finite? },
      "camera right vector went non-finite: #{camera.inspect}"
    assert_operator telemetry["frames"], :>, 0, "rendering stopped"
    assert_empty severe_console_errors
  end

  test "the right trigger accelerates" do
    start = position
    plug(buttons: { RT => 1.0 })
    sleep 2.0

    assert_operator telemetry["speed"], :>, 4.0, "RT did not accelerate"
    assert_operator travelled_forward(start), :>, 3.0
  end

  test "the left bumper brakes and reverses" do
    start = position
    plug(buttons: { LB => 1.0 })
    sleep 2.0

    assert_operator telemetry["speed"], :<, -1.0, "LB did not reverse"
    assert_operator travelled_forward(start), :<, -1.0
  end

  test "the right bumper fires the turbo" do
    plug(buttons: { RT => 1.0, RB => 1.0 })
    sleep 1.0

    assert_operator telemetry["turbo"], :<, 0.85, "RB did not drain the turbo bar"
  end

  test "the left stick steers" do
    plug(buttons: { RT => 1.0 })
    sleep 1.5
    plug(buttons: { RT => 1.0 }, axes: [ 0.9, 0, 0, 0 ])
    sleep 1.5

    assert_operator telemetry["steer"].abs, :>, 0.05, "left stick produced no steer angle"
  end

  test "the left trigger starts a drift" do
    plug(buttons: { RT => 1.0 })
    sleep 3.0
    plug(buttons: { RT => 1.0, LT => 1.0 }, axes: [ 0.9, 0, 0, 0 ])

    wait_for(timeout: 6, message: "LT never started a drift") { telemetry["drifting"] }
    # The drift angle eases in, so it is zero on the frame the drift begins.
    wait_for(timeout: 6, message: "drift never produced an angle") do
      telemetry["driftAngle"].abs > 0.1
    end
    assert telemetry["drifting"], "drift should still be held"
    assert_operator telemetry["driftAngle"].abs, :>, 0.1
  end

  test "the A button is the action key" do
    resting = telemetry["y"]
    plug(buttons: { A => 1.0 })
    sleep 1.2

    assert_operator telemetry["y"], :>, resting + 1.0, "A did not fire the jump jets"
  end

  test "an idle stick inside the deadzone changes nothing" do
    plug(axes: [ 0.05, -0.05, 0.05, -0.05 ])
    sleep 1.2

    assert_in_delta 0.0, telemetry["steer"], 0.01, "deadzone leaked into steering"
    assert_empty severe_console_errors
  end

  private
    def telemetry
      page.evaluate_script("window.__arena")
    end

    def position
      t = telemetry
      [ t["x"], t["y"], t["z"] ]
    end

    # Spawns follow the track heading, so measure along the car's own forward vector.
    def travelled_forward(start)
      t = telemetry
      moved = [ t["x"] - start[0], t["y"] - start[1], t["z"] - start[2] ]
      moved.zip(t["forward"]).sum { |a, b| a * b }
    end

    def plug(axes: [ 0, 0, 0, 0 ], buttons: {})
      page.execute_script(<<~JS, axes, buttons.transform_keys(&:to_s))
        const axes = arguments[0]
        const pressed = arguments[1]
        const buttons = Array.from({ length: 17 }, (_, i) => {
          const value = Number(pressed[String(i)] || 0)
          return { pressed: value > 0.5, value, touched: value > 0 }
        })
        navigator.getGamepads = () => [{
          id: "fake pad", index: 0, connected: true, mapping: "standard",
          axes, buttons, timestamp: performance.now()
        }]
      JS
    end

    def unplug
      page.execute_script("navigator.getGamepads = () => []")
    rescue StandardError
      nil
    end
end
