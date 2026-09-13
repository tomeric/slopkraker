import * as THREE from "three"

// The live readout published as `window.__arena`. It is the debug overlay's data source
// and the system suite's only window onto the simulation -- Selenium cannot see the
// Three.js scene, so anything a browser test asserts has to arrive through here.
//
// Kept out of the engine because assembling it was a third of the render frame and none
// of it is the loop's business. The engine writes the counters it owns (steps, frames,
// broken, explosions) directly; everything derived from the vehicle is gathered here.
export class Telemetry {
  constructor() {
    this.stats = {
      // Lifecycle and rates.
      ready: false, frames: 0, steps: 0, bodies: 0, fps: 0, error: null,

      // Where the car is and which way it faces. `forward` matters because spawns follow
      // the track heading, so it is never a world axis; `camRight` is the only definition
      // of "right" that matches what the player actually sees.
      x: 0, y: 0, z: 0, yaw: 0, upDot: 1,
      forward: [ 0, 0, 1 ], camRight: [ 1, 0, 0 ],

      // Motion.
      speed: 0, planarSpeed: 0, verticalSpeed: 0, fallSpeed: 0,
      yawRate: 0, pitchRate: 0, grounded: 0,

      // Driver input and the systems it drives.
      throttle: 0, steer: 0, turbo: 1, turboOn: false, jets: 0,
      boostCharged: false, boosting: false,

      // Drift and slam.
      slip: 0, slipAngle: 0, drifting: false, driftDir: 0, driftGrace: 0,
      driftTime: 0, driftAngle: 0, driftTarget: 0, driftTurnRate: 0,
      slamming: false, slamTime: 0, slamThrust: 0, boosters: [], bullBar: null,

      // Ordnance and its consequences.
      rockets: 0, rocketsFired: 0, rocketReadout: [],
      explosions: 0, explosionReadout: [],
      debris: 0, broken: 0, hitMarkers: 0, damage: [], lastDamage: 0,

      vehicle: null, muted: false
    }

    // Reused every frame rather than allocating a vector per frame to read one dot
    // product.
    this.scratch = new THREE.Vector3()
  }

  update({
    vehicle, vehicleKey, entity, camera, projectiles, explosions,
    destruction, hitMarkers, damageGizmos, audio, input, fallSpeed
  }) {
    const stats = this.stats

    stats.vehicle = vehicleKey
    stats.x = entity.renderPos.x
    stats.y = entity.renderPos.y
    stats.z = entity.renderPos.z
    stats.upDot = vehicle._up.y
    stats.yaw = Math.atan2(vehicle._forward.x, vehicle._forward.z)
    stats.forward = [ vehicle._forward.x, vehicle._forward.y, vehicle._forward.z ]

    const m = camera.matrixWorld.elements
    stats.camRight = [ m[0], m[1], m[2] ]

    stats.grounded = vehicle.groundedWheels()
    stats.speed = vehicle.speed
    stats.planarSpeed = vehicle.planarSpeed
    stats.verticalSpeed = vehicle.body.linvel().y
    stats.fallSpeed = fallSpeed

    const angvel = vehicle.body.angvel()
    stats.yawRate = angvel.y
    stats.pitchRate = vehicle._right.dot(this.scratch.set(angvel.x, angvel.y, angvel.z))

    stats.throttle = input.throttle
    stats.steer = vehicle.steerAngle
    stats.turbo = vehicle.turboBar.fraction
    stats.turboOn = vehicle.turboActive
    stats.jets = vehicle.jetThrottle || 0
    stats.boostCharged = vehicle.boostCharged
    stats.boosting = vehicle.boostTime > 0

    stats.slip = vehicle.lateralSlip()
    stats.slipAngle = vehicle.slipAngle()
    stats.drifting = vehicle.drifting
    stats.driftDir = vehicle.driftDirection
    stats.driftGrace = vehicle.driftGrace
    stats.driftTime = vehicle.driftTime
    stats.driftAngle = vehicle.driftAngle
    stats.driftTarget = vehicle.driftTarget
    stats.driftTurnRate = vehicle.driftTurnRate
    stats.slamming = vehicle.slamming
    stats.slamTime = vehicle.slamTime
    stats.slamThrust = vehicle.slamThrust || 0
    // Read from the view, not the vehicle: the flames report what updateAirControl
    // actually applied, which is not what the stick asked for whenever one of its gates
    // is holding the chassis still.
    stats.boosters = entity.view.boosterReadout
    stats.bullBar = vehicle.bullBarBox()

    stats.rockets = projectiles.live.length
    stats.rocketsFired = projectiles.fired
    stats.rocketReadout = projectiles.live.map((rocket) => ({
      damage: Math.round(rocket.damage),
      speed: Math.round(rocket.speed || rocket.spec.launch_speed),
      phase: rocket.phase
    }))
    stats.explosionReadout = explosions.readout()
    stats.debris = destruction.debris.length
    stats.hitMarkers = hitMarkers.live.length
    if (damageGizmos) stats.damage = damageGizmos.readout

    stats.audio = {
      enabled: audio.engine.enabled,
      state: audio.engine.ctx ? audio.engine.ctx.state : "none",
      voices: audio.engine.voices.length
    }
  }

  frame(frameTime) {
    this.stats.frames += 1
    if (frameTime > 0) this.stats.fps = Math.round(1 / frameTime)
  }
}
