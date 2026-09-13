// Standard Gamepad API mapping, polled once per frame. Triggers are analogue buttons so
// they carry a value rather than a pressed flag.
export class GamepadSource {
  constructor(bindings, cameraSpec) {
    this.bindings = bindings
    this.stickSensitivity = cameraSpec.stick_sensitivity
    this.previousButtons = new Map()
  }

  pad() {
    const pads = navigator.getGamepads ? navigator.getGamepads() : []
    for (const pad of pads) {
      if (pad && pad.connected) return pad
    }
    return null
  }

  get connected() {
    return this.pad() !== null
  }

  axis(pad, index, deadzone) {
    const raw = pad.axes[index] ?? 0
    if (Math.abs(raw) < deadzone) return 0
    // Rescale past the deadzone so the stick still reaches full lock.
    const sign = Math.sign(raw)
    return sign * ((Math.abs(raw) - deadzone) / (1 - deadzone))
  }

  buttonValue(pad, index) {
    const button = pad.buttons[index]
    if (!button) return 0
    return typeof button.value === "number" ? button.value : button.pressed ? 1 : 0
  }

  tapped(pad, index) {
    const pressed = this.buttonValue(pad, index) > 0.5
    const was = this.previousButtons.get(index) || false
    this.previousButtons.set(index, pressed)
    return pressed && !was
  }

  apply(input) {
    const pad = this.pad()
    if (!pad) return

    const b = this.bindings
    const dead = b.deadzone
    const triggerDead = b.trigger_deadzone

    const throttle = this.buttonValue(pad, b.throttle.button)
    const brake = this.buttonValue(pad, b.brake.button)
    if (throttle > triggerDead) input.throttle = Math.max(input.throttle, throttle)
    if (brake > triggerDead) input.brake = Math.max(input.brake, brake)

    const steer = this.axis(pad, b.steer.axis, dead)
    if (steer !== 0) {
      // A mild curve buys precision around centre without losing full lock.
      input.steer = Math.sign(steer) * Math.pow(Math.abs(steer), b.steer_curve)
    }

    // Stick up reads negative on the Gamepad API, and up means nose down.
    const pitch = this.axis(pad, b.pitch.axis, dead)
    if (pitch !== 0) input.pitch = -pitch

    if (this.buttonValue(pad, b.slide.button) > 0.5) input.slide = true
    if (this.tapped(pad, b.slide.button)) input.slidePressed = true
    if (this.buttonValue(pad, b.turbo.button) > 0.5) input.turbo = true
    if (this.buttonValue(pad, b.action.button) > 0.5) input.action = true

    input.cameraYaw -= this.axis(pad, b.camera_yaw.axis, dead) * this.stickSensitivity * 0.016
    input.cameraPitch -= this.axis(pad, b.camera_pitch.axis, dead) * this.stickSensitivity * 0.016

    if (this.tapped(pad, b.respawn.button)) input.respawn = true
    if (this.tapped(pad, b.camera_recentre.button)) input.cameraRecentre = true
    if (this.tapped(pad, b.switch_vehicle.button)) input.switchVehicle = true
    if (this.tapped(pad, b.toggle_controls.button)) input.toggleControls = true
    if (this.tapped(pad, b.toggle_debug.button)) input.toggleDebug = true
    if (this.tapped(pad, b.toggle_mute.button)) input.toggleMute = true
  }

  dispose() {}
}
