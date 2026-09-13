import * as THREE from "three"

const UP = new THREE.Vector3(0, 1, 0)

// Follows behind the vehicle, lagging under acceleration. The player can swing it
// around; those offsets spring back to centre once they stop, which is the "always
// drifts back to default" behaviour.
export class ChaseCamera {
  constructor(camera, spec) {
    this.camera = camera
    this.spec = spec

    this.orbitYaw = 0
    this.orbitPitch = 0
    this.idleTime = 0
    this.driftLook = 0

    this.position = new THREE.Vector3()
    this.lookAt = new THREE.Vector3()
    this.fov = spec.base_fov
    this.initialised = false

    this._offset = new THREE.Vector3()
    this._lookOffset = new THREE.Vector3()
    this._desired = new THREE.Vector3()
    this._desiredLook = new THREE.Vector3()
    this._euler = new THREE.Euler(0, 0, 0, "YXZ")
    this._quat = new THREE.Quaternion()
  }

  recentre() {
    this.orbitYaw = 0
    this.orbitPitch = 0
  }

  update(dt, targetPosition, targetQuaternion, speed, input, turboActive, driftDirection = 0) {
    const s = this.spec

    // A single non-finite value would poison the camera transform forever and render a
    // black screen with nothing logged. Refuse it at the boundary.
    const yawInput = Number.isFinite(input.cameraYaw) ? input.cameraYaw : 0
    const pitchInput = Number.isFinite(input.cameraPitch) ? input.cameraPitch : 0

    if (yawInput !== 0 || pitchInput !== 0) {
      this.orbitYaw = clamp(this.orbitYaw + yawInput, -s.max_orbit_yaw, s.max_orbit_yaw)
      this.orbitPitch = clamp(this.orbitPitch + pitchInput, -s.max_orbit_pitch, s.max_orbit_pitch)
      this.idleTime = 0
    } else {
      this.idleTime += dt
    }
    if (input.cameraRecentre) this.recentre()

    // Spring the orbit back to centre once the player stops steering the camera.
    if (this.idleTime > s.orbit_return_delay) {
      const k = 1 - Math.exp(-s.orbit_return_stiffness * dt)
      this.orbitYaw += (0 - this.orbitYaw) * k
      this.orbitPitch += (0 - this.orbitPitch) * k
    }

    // Swing round to look into the corner while drifting. The camera moves opposite to
    // the drift so its view rotates toward where the car is heading, which is what makes
    // a drift readable instead of a sideways surprise.
    const lookTarget = -driftDirection * s.drift_look
    this.driftLook += (lookTarget - this.driftLook) * (1 - Math.exp(-s.drift_look_stiffness * dt))

    // Follow the chassis yaw only -- inheriting roll and pitch would make the camera sick
    // every time the vehicle lands.
    this._euler.setFromQuaternion(targetQuaternion, "YXZ")
    const yaw = this._euler.y

    this._euler.set(this.orbitPitch, yaw + this.orbitYaw + this.driftLook, 0, "YXZ")
    this._quat.setFromEuler(this._euler)

    this._offset.fromArray(s.offset).applyQuaternion(this._quat)
    this._desired.copy(targetPosition).add(this._offset)

    this._euler.set(0, yaw, 0, "YXZ")
    this._lookOffset.fromArray(s.look_at_offset).applyQuaternion(this._quat.setFromEuler(this._euler))
    this._desiredLook.copy(targetPosition).add(this._lookOffset)

    if (!this.initialised) {
      this.position.copy(this._desired)
      this.lookAt.copy(this._desiredLook)
      this.initialised = true
    } else {
      // Exponential smoothing keyed off real frame time, so feel is frame-rate independent.
      this.position.lerp(this._desired, 1 - Math.exp(-s.follow_stiffness * dt))
      this.lookAt.lerp(this._desiredLook, 1 - Math.exp(-s.look_stiffness * dt))
    }

    const targetFov = Math.min(
      s.base_fov + Math.abs(speed) * s.speed_fov_gain + (turboActive ? s.turbo_fov_kick : 0),
      s.max_fov
    )
    this.fov += (targetFov - this.fov) * (1 - Math.exp(-6 * dt))

    this.camera.position.copy(this.position)
    this.camera.up.copy(UP)
    this.camera.lookAt(this.lookAt)
    if (Math.abs(this.camera.fov - this.fov) > 0.01) {
      this.camera.fov = this.fov
      this.camera.updateProjectionMatrix()
    }
  }
}

function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max)
}
