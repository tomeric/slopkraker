// Built from the Ruby bindings rather than hand-written markup, so the panel can never
// document a key that no longer does anything.
//
// Highlighting keys off the merged InputState, which means a control lights up whether
// it was triggered by keyboard or gamepad -- the panel shows what the game heard.
const FLASH_SECONDS = 0.25
const AXIS_THRESHOLD = 0.05

export class ControlsOverlay {
  constructor(root, inputSpec, { actionLabel } = {}) {
    this.muted = false
    this.root = root
    this.entries = new Map()
    this.flashes = new Map()
    this.visible = true

    this.element = document.createElement("div")
    this.element.className = "controls"

    const heading = document.createElement("div")
    heading.className = "controls__heading"
    heading.textContent = "Controls"
    this.padBadge = document.createElement("span")
    this.padBadge.className = "controls__pad-badge"
    this.padBadge.textContent = "no pad"
    heading.appendChild(this.padBadge)
    this.element.appendChild(heading)

    for (const entry of inputSpec.display) {
      this.element.appendChild(this.buildRow(entry))
    }

    root.appendChild(this.element)
    this.setActionLabel(actionLabel)
  }

  buildRow(entry) {
    const row = document.createElement("div")
    row.className = "controls__row"

    const label = document.createElement("span")
    label.className = "controls__label"
    label.textContent = entry.label

    const keys = document.createElement("span")
    keys.className = "controls__keys"
    for (const key of entry.keys) {
      const kbd = document.createElement("kbd")
      kbd.textContent = key
      keys.appendChild(kbd)
    }

    const pad = document.createElement("span")
    pad.className = "controls__pad"
    if (entry.pad) pad.textContent = entry.pad

    row.append(label, keys, pad)
    this.entries.set(entry.control, { row, label, active: false })
    return row
  }

  setActionLabel(actionLabel) {
    const entry = this.entries.get("action")
    if (entry && actionLabel) entry.label.textContent = actionLabel
  }

  // Momentary controls fire for a single frame, which would be invisible; hold the
  // highlight briefly so the press actually reads.
  flash(control) {
    this.flashes.set(control, FLASH_SECONDS)
  }

  update(dt, state, padConnected) {
    if (state.toggleControls) this.toggle()

    for (const [control, remaining] of this.flashes) {
      const left = remaining - dt
      if (left <= 0) this.flashes.delete(control)
      else this.flashes.set(control, left)
    }

    this.apply("throttle", state.throttle > AXIS_THRESHOLD)
    this.apply("brake", state.brake > AXIS_THRESHOLD)
    this.apply("steer_left", state.steer < -AXIS_THRESHOLD)
    this.apply("steer_right", state.steer > AXIS_THRESHOLD)
    this.apply("pitch_forward", state.pitch > AXIS_THRESHOLD)
    this.apply("pitch_back", state.pitch < -AXIS_THRESHOLD)
    this.apply("slide", state.slide)
    this.apply("turbo", state.turbo)
    this.apply("action", state.action)
    this.apply("toggle_mute", this.muted)

    for (const control of [ "respawn", "camera_recentre", "switch_vehicle", "toggle_controls" ]) {
      this.apply(control, this.flashes.has(control))
    }

    const badge = padConnected ? "gamepad" : "no pad"
    if (this.padBadge.textContent !== badge) {
      this.padBadge.textContent = badge
      this.padBadge.classList.toggle("is-connected", padConnected)
    }
  }

  // Only touch the DOM when a control actually changes state.
  apply(control, active) {
    const entry = this.entries.get(control)
    if (!entry || entry.active === !!active) return

    entry.active = !!active
    entry.row.classList.toggle("is-active", entry.active)
  }

  toggle() {
    this.visible = !this.visible
    this.element.classList.toggle("is-hidden", !this.visible)
  }

  dispose() {
    this.element.remove()
  }
}
