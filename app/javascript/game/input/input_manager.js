import { InputState } from "game/input/input_state"
import { KeyboardSource } from "game/input/keyboard_source"
import { PointerSource } from "game/input/pointer_source"
import { GamepadSource } from "game/input/gamepad_source"

function finite(value) {
  return Number.isFinite(value) ? value : 0
}

export class InputManager {
  constructor(element, bindings, cameraSpec) {
    this.state = new InputState()
    this.keyboard = new KeyboardSource(bindings.keyboard)
    this.pointer = new PointerSource(element, cameraSpec.orbit_sensitivity)
    this.gamepad = new GamepadSource(bindings.gamepad, cameraSpec)
    this.sources = [this.keyboard, this.pointer, this.gamepad]
  }

  // Sampled once per frame; every physics substep in that frame reads the same input.
  sample() {
    const state = this.state
    state.throttle = 0
    state.brake = 0
    state.steer = 0
    state.pitch = 0
    state.slide = false
    state.slidePressed = false
    state.turbo = false
    state.action = false

    for (const source of this.sources) source.apply(state)

    // Debug/test hook: lets a script drive the vehicle directly, bypassing the jitter of
    // synthetic key events. Also what a replay or demo mode would use.
    if (window.__arenaInput) Object.assign(state, window.__arenaInput)

    // A NaN here reaches the solver and corrupts the whole simulation silently.
    state.throttle = finite(state.throttle)
    state.brake = finite(state.brake)
    state.steer = finite(state.steer)
    state.pitch = finite(state.pitch)

    return state
  }

  dispose() {
    for (const source of this.sources) source.dispose()
  }
}
