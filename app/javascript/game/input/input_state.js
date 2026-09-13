// One normalised struct every input source writes into. Keeping sources behind a single
// shape is also what makes the network layer trivial later.
export class InputState {
  constructor() {
    this.throttle = 0      // 0..1
    this.brake = 0         // 0..1
    this.steer = 0         // -1 (left) .. 1 (right)
    this.pitch = 0         // airborne only: +1 noses down, -1 noses up
    this.slide = false        // held
    this.slidePressed = false // press edge: fires the hop
    this.turbo = false
    this.action = false
    this.cameraYaw = 0     // delta this frame
    this.cameraPitch = 0
    this.respawn = false
    this.cameraRecentre = false
    this.toggleTuning = false
    this.switchVehicle = false
    this.toggleControls = false
    this.toggleDebug = false
    this.toggleMute = false
  }

  // Camera deltas and edge-triggered flags are consumed each frame; analogue axes persist.
  endFrame() {
    this.slidePressed = false
    this.cameraYaw = 0
    this.cameraPitch = 0
    this.respawn = false
    this.cameraRecentre = false
    this.toggleTuning = false
    this.switchVehicle = false
    this.toggleControls = false
    this.toggleDebug = false
    this.toggleMute = false
  }
}
