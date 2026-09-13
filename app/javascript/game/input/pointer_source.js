// Drag anywhere on the canvas to swing the camera. Deltas are consumed per frame; the
// chase camera decides how they decay back to centre.
export class PointerSource {
  constructor(element, sensitivity) {
    this.element = element
    this.sensitivity = sensitivity
    this.dragging = false
    this.yaw = 0
    this.pitch = 0

    this.onDown = (event) => {
      if (event.button !== 0) return
      this.dragging = true
      this.element.setPointerCapture?.(event.pointerId)
    }
    this.onMove = (event) => {
      if (!this.dragging) return
      this.yaw -= event.movementX * this.sensitivity
      this.pitch -= event.movementY * this.sensitivity
    }
    this.onUp = () => { this.dragging = false }

    element.addEventListener("pointerdown", this.onDown)
    element.addEventListener("pointermove", this.onMove)
    window.addEventListener("pointerup", this.onUp)
    element.addEventListener("contextmenu", (e) => e.preventDefault())
  }

  apply(input) {
    input.cameraYaw += this.yaw
    input.cameraPitch += this.pitch
    this.yaw = 0
    this.pitch = 0
  }

  dispose() {
    this.element.removeEventListener("pointerdown", this.onDown)
    this.element.removeEventListener("pointermove", this.onMove)
    window.removeEventListener("pointerup", this.onUp)
  }
}
