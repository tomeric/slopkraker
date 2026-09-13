// Maps KeyboardEvent.code values to the shared input struct using the Ruby bindings.
export class KeyboardSource {
  constructor(bindings) {
    this.bindings = bindings
    this.pressed = new Set()
    this.edges = new Set()

    this.onKeyDown = (event) => {
      if (event.repeat) return
      if (this.owns(event.code)) event.preventDefault()
      this.pressed.add(event.code)
      this.edges.add(event.code)
    }
    this.onKeyUp = (event) => this.pressed.delete(event.code)
    this.onBlur = () => this.pressed.clear()

    window.addEventListener("keydown", this.onKeyDown)
    window.addEventListener("keyup", this.onKeyUp)
    window.addEventListener("blur", this.onBlur)
  }

  owns(code) {
    return Object.values(this.bindings).some((codes) => codes.includes(code))
  }

  held(control) {
    const codes = this.bindings[control] || []
    return codes.some((code) => this.pressed.has(code))
  }

  tapped(control) {
    const codes = this.bindings[control] || []
    return codes.some((code) => this.edges.has(code))
  }

  apply(input) {
    if (this.held("throttle")) input.throttle = 1
    if (this.held("brake")) input.brake = 1

    const left = this.held("steer_left") ? 1 : 0
    const right = this.held("steer_right") ? 1 : 0
    if (left || right) input.steer = right - left

    const down = this.held("pitch_forward") ? 1 : 0
    const up = this.held("pitch_back") ? 1 : 0
    if (down || up) input.pitch = down - up

    if (this.held("slide")) input.slide = true
    if (this.tapped("slide")) input.slidePressed = true
    if (this.held("turbo")) input.turbo = true
    if (this.held("action")) input.action = true

    if (this.tapped("respawn")) input.respawn = true
    if (this.tapped("camera_recentre")) input.cameraRecentre = true
    if (this.tapped("toggle_tuning")) input.toggleTuning = true
    if (this.tapped("switch_vehicle")) input.switchVehicle = true
    if (this.tapped("toggle_controls")) input.toggleControls = true
    if (this.tapped("toggle_debug")) input.toggleDebug = true
    if (this.tapped("toggle_mute")) input.toggleMute = true

    this.edges.clear()
  }

  dispose() {
    window.removeEventListener("keydown", this.onKeyDown)
    window.removeEventListener("keyup", this.onKeyUp)
    window.removeEventListener("blur", this.onBlur)
  }
}
