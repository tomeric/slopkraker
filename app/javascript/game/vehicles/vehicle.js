import * as THREE from "three"
import { createVehicleBody, applyWheelTuning } from "game/physics/vehicle_body"
import { TurboBar } from "game/turbo_bar"
import { vehicleGroups, reachingPartGroups, catchesWorld } from "game/physics/groups"

const WORLD_UP = new THREE.Vector3(0, 1, 0)
const REVERSE_THRESHOLD = 0.8

const lerp = (a, b, t) => a + (b - a) * t

// Half-extents and local offset in the shape Rapier's collider setters want.
function boxOf(size, offset) {
  return {
    half: { x: size[0] / 2, y: size[1] / 2, z: size[2] / 2 },
    at: { x: offset[0], y: offset[1], z: offset[2] }
  }
}

// Base driving behaviour shared by both vehicles: throttle, brake, reverse, steering,
// hop-to-drift, turbo, airborne weight-shift and flip recovery. Subclasses add the
// action key.
export class Vehicle {
  constructor({ RAPIER, world, spec, spawn, colliderIndex, meta }) {
    this.RAPIER = RAPIER
    this.world = world
    this.spec = spec
    this.spawn = spawn

    const built = createVehicleBody(RAPIER, world, spec, spawn, colliderIndex, meta)
    this.body = built.body
    this.controller = built.controller
    this.partColliders = built.partColliders

    this.turboBar = new TurboBar(spec.turbo_bar)
    this.steerAngle = 0
    this.turboActive = false

    // Drift state. A drift is entered on the hop, locked to the direction you were
    // steering, and sustained until you let go -- it is not a handbrake, so it keeps
    // speed rather than scrubbing it.
    this.drifting = false
    this.driftDirection = 0
    this.driftTime = 0
    this.hopCooldown = 0
    this.boostTime = 0
    this.boostCharged = false
    this.wheelCount = spec.wheels.length

    // Scratch objects reused every substep -- allocating per body per step at 120Hz is
    // real GC pressure and shows up as frame hitching.
    this._vec = { x: 0, y: 0, z: 0 }
    this._rot = { x: 0, y: 0, z: 0, w: 1 }
    this._quat = new THREE.Quaternion()
    this._forward = new THREE.Vector3()
    this._right = new THREE.Vector3()
    this._up = new THREE.Vector3()
    this._torque = new THREE.Vector3()
    this._angular = { x: 0, y: 0, z: 0 }
    this.exitFlickRemaining = 0
    this.exitDirection = 0

    // Drift readouts. Initialised here rather than left undefined until the first drift:
    // telemetry and the debug overlay read them every frame.
    this.driftAngle = 0
    this.driftTarget = 0
    this.driftTurnRate = 0
    this.driftSpeed = 0
    // Bonus parts that outlive their trigger. The bull bar keeps its multiplier for a
    // beat after the drift so a hit landing as you straighten up still counts.
    this.driftGrace = 0
    this.driftGraceDuration = spec.parts.find((p) => p.kind === "bull_bar")?.retain || 0
    this.slamming = false
    this.slamTime = 0
    // What updateAirControl actually did this frame, not what the stick asked for.
    this.airRoll = 0
    this.airPitch = 0
    this.prevSlip = 0
    this.slipRate = 0

    this.bullBar = this.rigBullBar(built.partColliders, meta.owner)

    this._pendingImpulse = new THREE.Vector3()
    this._hasImpulse = false
  }

  // Rapier's vehicle controller rewrites the chassis velocity inside updateVehicle(), so
  // an impulse applied before that call is simply discarded -- the same reason the drift
  // kinematics have to be the last word. Anything wanting to shove the car queues it here
  // and it lands afterwards.
  queueImpulse(vector) {
    this._pendingImpulse.add(vector)
    this._hasImpulse = true
  }

  flushImpulse() {
    if (!this._hasImpulse) return

    this.body.applyImpulse(this._pendingImpulse, true)
    this._pendingImpulse.set(0, 0, 0)
    this._hasImpulse = false
  }

  // The bull bar swings out to a bigger box while a drift has it armed. Both boxes are
  // Ruby's -- this only eases between the two it was handed.
  rigBullBar(partColliders, owner) {
    const entry = partColliders.find(({ part }) => part.kind === "bull_bar")
    if (!entry || !entry.part.slide_extension) return null

    const extension = entry.part.slide_extension
    return {
      collider: entry.collider,
      resting: boxOf(entry.part.size, entry.part.offset),
      reaching: boxOf(extension.size, extension.offset),
      restingGroups: vehicleGroups(owner),
      reachingGroups: reachingPartGroups(owner),
      easeTime: extension.ease_time,
      amount: 0
    }
  }

  // Forward speed projected from the body's own velocity rather than Rapier's
  // currentVehicleSpeed(), which reports phantom motion at rest -- enough to convince the
  // throttle the car is rolling backwards, so it brakes instead of pulling away.
  get speed() {
    const v = this.body.linvel(this._vec)
    return v.x * this._forward.x + v.y * this._forward.y + v.z * this._forward.z
  }

  // Speed along the ground, regardless of which way the car is pointing. In a drift the
  // forward-axis component collapses (and can go negative) while the car is still
  // travelling fast, so momentum has to be measured this way.
  get planarSpeed() {
    const v = this.body.linvel(this._vec)
    return Math.hypot(v.x, v.z)
  }

  groundedWheels() {
    let count = 0
    for (let i = 0; i < this.wheelCount; i += 1) {
      if (this.controller.wheelIsInContact(i)) count += 1
    }
    return count
  }

  // Forward is +Z because that is the axis Rapier's vehicle controller treats as forward
  // (setIndexForwardAxis = 2). Given up = +Y, the driver's right is therefore -X:
  // looking along +Z with +Y up, right = forward x up = (-1, 0, 0). Getting this wrong
  // mirrors steering, banking and the rocket arc all at once.
  refreshBasis() {
    const r = this.body.rotation(this._rot)
    this._quat.set(r.x, r.y, r.z, r.w)
    this._forward.set(0, 0, 1).applyQuaternion(this._quat)
    this._right.set(-1, 0, 0).applyQuaternion(this._quat)
    this._up.set(0, 1, 0).applyQuaternion(this._quat)
  }

  // Sideways speed in chassis space (m/s). Right for tyre-squeal volume, which should
  // scale with how fast the rubber is being dragged.
  lateralSlip() {
    const v = this.body.linvel(this._vec)
    return v.x * this._right.x + v.y * this._right.y + v.z * this._right.z
  }

  // Angle between where the vehicle points and where it is actually going, in radians.
  // This -- not absolute lateral speed -- is what distinguishes a slide from a fast
  // grippy corner: a drift scrubs some speed, so its lateral velocity can be lower
  // than a committed corner's while being far more sideways.
  // Signed: negative when the velocity sits to the driver's left of the nose, which is
  // what a right-hand drift looks like.
  signedSlipAngle() {
    const v = this.body.linvel(this._vec)
    const lateral = v.x * this._right.x + v.y * this._right.y + v.z * this._right.z
    const forward = v.x * this._forward.x + v.y * this._forward.y + v.z * this._forward.z
    if (Math.hypot(lateral, forward) < 0.5) return 0
    return Math.atan2(lateral, Math.abs(forward))
  }

  slipAngle() {
    const v = this.body.linvel(this._vec)
    const lateral = v.x * this._right.x + v.y * this._right.y + v.z * this._right.z
    const forward = v.x * this._forward.x + v.y * this._forward.y + v.z * this._forward.z
    if (Math.hypot(lateral, forward) < 0.5) return 0
    return Math.atan2(Math.abs(lateral), Math.abs(forward))
  }

  update(dt, input) {
    this.refreshBasis()
    const speed = this.speed
    const grounded = this.groundedWheels()

    this.updateSteering(dt, input, speed)
    this.turboActive = this.updateTurbo(dt, input, grounded)
    this.updateSlide(dt, input, grounded, this.planarSpeed)
    this.updateDrive(dt, input, speed)
    this.applyDriftGrip()
    this.updateTrailBraking(dt, input, grounded, speed)
    this.updateAirControl(dt, input, grounded)
    this.updateFlipRecovery(dt, input, speed)
    this.updateAction(dt, input, grounded)

    // Rapier does not touch vehicle controllers during world.step(); this must run first
    // because it writes directly into the chassis velocity.
    this.driftGrace = Math.max(0, this.driftGrace - dt)

    this.controller.updateVehicle(dt)

    // Queued shoves land here: applied any earlier, updateVehicle discards them.
    this.flushImpulse()

    // The drift overrides velocity direction and yaw, so it has to be the last word
    // before the solver runs -- updateVehicle would otherwise undo it.
    if (this.drifting && grounded > 0) this.applyDriftKinematics(dt, input)
    else this.updateExitFlick(dt)

    // Last, so the bar is sized off the slip angle this frame actually ended up with.
    this.updateBullBar(dt)

    this.turboBar.update(dt)
  }

  updateSteering(dt, input, speed) {
    const s = this.spec.steering
    // Less lock at speed, or the car darts. Never below minimum_angle_ratio.
    const ratio = Math.min(Math.abs(speed) / Math.max(this.spec.engine.top_speed, 1), 1)
    let authority = 1 - (1 - s.minimum_angle_ratio) * ratio * s.speed_falloff
    // Under the brakes the front axle is loaded, so it can take more lock.
    authority *= 1 + input.brake * s.brake_turn_assist
    const target = input.steer * s.max_angle * authority

    // Mid-drift the front wheels hold a fixed lock: letting the stick drive them would
    // tighten the arc, which is exactly what the pedals are for.
    const steerTarget = this.drifting
      ? this.driftDirection * s.max_angle * this.spec.slide.steer_lock
      : target

    const rate = Math.abs(steerTarget) > Math.abs(this.steerAngle) ? s.rate : s.return_rate
    const step = rate * s.max_angle * dt
    const delta = steerTarget - this.steerAngle
    this.steerAngle += Math.sign(delta) * Math.min(Math.abs(delta), step)

    // Rapier's positive steer angle rotates +Z toward +X, which is the driver's LEFT, so
    // the sign is inverted on the way in. steerAngle stays in driver terms: + is right.
    this.spec.wheels.forEach((wheel, i) => {
      if (wheel.steered) this.controller.setWheelSteering(i, -this.steerAngle)
    })
  }

  updateTurbo(dt, input, grounded) {
    if (!input.turbo) return false
    return this.turboBar.draw(this.spec.turbo.drain_rate * dt)
  }

  // NOTE on units: Rapier follows Bullet here, where wheel ENGINE FORCE is a force
  // (internally multiplied by the timestep) but wheel BRAKE is applied directly as an
  // impulse. Ruby specifies both in newtons, so the brake is converted here. Passing a
  // force straight through makes braking ~120x too strong -- enough that merely lifting
  // off the throttle stops the car dead.
  updateDrive(dt, input, speed) {
    const engine = this.spec.engine
    const boosting = this.boostTime > 0
    const slideBoost = this.spec.slide.boost
    const boost =
      (this.turboActive ? this.spec.turbo.force_multiplier : 1) *
      (boosting ? slideBoost.force_multiplier : 1)
    const topSpeed =
      engine.top_speed *
      (this.turboActive ? this.spec.turbo.top_speed_multiplier : 1) *
      (boosting ? slideBoost.top_speed_multiplier : 1)

    let engineForce = 0
    let brakeForce = 0

    if (input.throttle > 0) {
      // Throttle while rolling backwards is a brake, not a gear change.
      if (speed < -REVERSE_THRESHOLD) {
        brakeForce = engine.brake_force * input.throttle
      } else if (speed < topSpeed) {
        engineForce = engine.force * input.throttle * boost
      }
    } else if (input.brake > 0) {
      if (speed > REVERSE_THRESHOLD) {
        const scale = this.drifting ? this.spec.slide.brake_scale : 1
        brakeForce = engine.brake_force * input.brake * scale
      } else if (speed > -engine.reverse_top_speed) {
        engineForce = -engine.reverse_force * input.brake
      }
    } else {
      brakeForce = engine.engine_braking
    }

    // Mid-drift the drift kinematics own speed; leaving the wheels driving or braking
    // would double up and scrub.
    if (this.drifting) {
      this.spec.wheels.forEach((_, i) => {
        this.controller.setWheelEngineForce(i, 0)
        this.controller.setWheelBrake(i, 0)
      })
      return
    }

    const drivenCount = this.spec.wheels.filter((w) => w.driven).length || 1
    const perWheel = engineForce / drivenCount

    this.spec.wheels.forEach((wheel, i) => {
      this.controller.setWheelEngineForce(i, wheel.driven ? perWheel : 0)
      this.controller.setWheelBrake(i, (brakeForce * dt) / this.wheelCount)
    })
  }

  // Mario-Kart-style: tap to hop, hold to drift. The hop is what lets you commit to a
  // corner before you reach it, and the drift holds a locked direction so the car stays
  // predictable while sideways. Steering modulates how tight the drift is rather than
  // fighting it.
  // `speed` here is planar, not forward-axis: see the getter above.
  updateSlide(dt, input, grounded, speed) {
    const s = this.spec.slide
    this.hopCooldown = Math.max(0, this.hopCooldown - dt)
    if (this.boostTime > 0) this.boostTime = Math.max(0, this.boostTime - dt)

    // Hop fires on the press edge, not while held.
    if (input.slidePressed && grounded > 0 && this.hopCooldown === 0) {
      this._torque.copy(this._up).multiplyScalar(s.hop_impulse)
      this.body.applyImpulse(this._torque, true)
      this.hopCooldown = s.hop_cooldown
    }

    if (!this.drifting) {
      const wants = input.slide && Math.abs(input.steer) >= s.engage_steer
      if (wants && grounded > 0 && speed >= s.min_speed) {
        this.drifting = true
        this.driftDirection = Math.sign(input.steer)
        this.driftTime = 0
        this.boostCharged = false
        this.prevSlip = this.signedSlipAngle()
        this.slipRate = 0
        this.driftSpeed = this.planarSpeed
      }
      return
    }

    if (!input.slide || speed < s.exit_speed) {
      this.endDrift(speed < s.exit_speed)
      return
    }

    this.driftTime += dt
    if (this.driftTime >= s.boost.charge_time) this.boostCharged = true

    // Grip cannot produce the drift without scrubbing the momentum away, so the arc and
    // the angle are driven directly in applyDriftKinematics() after updateVehicle().

  }

  // Releasing a drift flicks the car out of the corner: the chassis rotates back against
  // the drift and is kicked along that new heading. Without it, control returns to
  // heavily scrubbed tyres while the car is still sideways, which reads as braking into
  // the corner. Holding the drift long enough also banks a mini-turbo.
  endDrift(stalled) {
    const s = this.spec.slide

    if (!stalled) {
      if (this.boostCharged) this.boostTime = s.boost.duration
      this.driftGrace = this.driftGraceDuration
      // Hand off to updateExitFlick rather than snapping the car round here.
      this.exitFlickRemaining = s.exit_time
      this.exitDirection = this.driftDirection
    }

    this.drifting = false
    this.driftDirection = 0
    this.driftTime = 0
    this.boostCharged = false
  }

  // A drift is a deliberate arcade behaviour, so it is driven rather than coaxed out of
  // the tyre model:
  //
  //   * the planar velocity is ROTATED, never rescaled, so the car keeps its momentum
  //     through the corner instead of scrubbing it off;
  //   * the chassis is pointed ahead of that velocity by the drift angle, which is what
  //     makes the car actually look sideways rather than merely travel sideways.
  //
  // Pedals set the arc: throttle and turbo widen it, brake tightens it.
  applyDriftKinematics(dt, input) {
    const s = this.spec.slide
    const v = this.body.linvel(this._vec)
    const planar = Math.hypot(v.x, v.z)
    if (planar < 0.5) return

    const widen = input.throttle * s.throttle_widen + (this.turboActive ? s.turbo_widen : 0)
    const tighten = input.brake * s.brake_tighten
    const modulation = Math.min(Math.max(tighten - widen, -1), 1)
    const blend = 0.5 + 0.5 * modulation

    // Pedals set the base arc; the stick trims it within bounds. Leaning into the corner
    // tightens, leaning out widens -- but neither can wind the arc down indefinitely.
    const lean = Math.min(Math.max(input.steer * this.driftDirection, -1), 1)
    const base = s.min_turn_rate + (s.max_turn_rate - s.min_turn_rate) * blend

    // Floor and ceiling on the result, both scaled off the pedal range by the spec. At
    // full trim the multiplicative bound would otherwise open the arc out to a
    // near-straight line, which reads as the drift having quietly stopped working rather
    // than as running it wide -- and wind it down to a spin at the other end.
    const turnRate = Math.min(
      Math.max(base * (1 + lean * s.steer_arc_bounds), s.min_turn_rate * s.arc_floor_scale),
      s.max_turn_rate * s.arc_ceiling_scale
    )
    // Ease the angle in over entry_time so the nose swings round rather than snapping.
    const entry = Math.min(this.driftTime / s.entry_time, 1)
    const driftAngle = (s.min_angle + (s.max_angle - s.min_angle) * blend) * entry

    // Turning right rotates negatively about +Y.
    const omega = -this.driftDirection * turnRate
    const theta = omega * dt
    const cos = Math.cos(theta)
    const sin = Math.sin(theta)

    const rotatedX = v.x * cos + v.z * sin
    const rotatedZ = -v.x * sin + v.z * cos

    // Speed is carried explicitly rather than left to the tyres, which would scrub a
    // third of it off through the corner. Throttle builds it, brake sheds it at a
    // controlled rate, coasting bleeds a little.
    const engine = this.spec.engine
    const accel = (engine.force / this.spec.chassis.mass) * s.accel_scale *
      (this.turboActive ? this.spec.turbo.force_multiplier : 1) *
      (this.boostTime > 0 ? this.spec.slide.boost.force_multiplier : 1)

    let target = this.driftSpeed
    if (input.throttle > 0) target += accel * input.throttle * dt
    if (input.brake > 0) target -= s.brake_decel * input.brake * dt
    target -= s.coast_decel * dt

    const topSpeed = engine.top_speed * s.speed_cap *
      (this.turboActive ? this.spec.turbo.top_speed_multiplier : 1)
    this.driftSpeed = Math.min(Math.max(target, 0), topSpeed)

    const scale = this.driftSpeed / planar
    this.body.setLinvel({ x: rotatedX * scale, y: v.y, z: rotatedZ * scale }, true)

    const nextX = rotatedX * scale
    const nextZ = rotatedZ * scale

    // Cock the nose into the corner: ahead of the direction of travel.
    const travelYaw = Math.atan2(nextX, nextZ)
    const desiredYaw = travelYaw - this.driftDirection * driftAngle
    const currentYaw = Math.atan2(this._forward.x, this._forward.z)

    let error = desiredYaw - currentYaw
    while (error > Math.PI) error -= 2 * Math.PI
    while (error < -Math.PI) error += 2 * Math.PI

    const correction = Math.min(Math.max(error * s.yaw_snap, -s.max_yaw_rate), s.max_yaw_rate)
    const angular = this.body.angvel(this._angular)
    this.body.setAngvel({ x: angular.x, y: omega + correction, z: angular.z }, true)

    this.driftAngle = this.signedSlipAngle()
    this.driftTarget = -this.driftDirection * driftAngle
    this.driftTurnRate = turnRate
  }

  // The flick is eased in over exit_time: the chassis rotates back against the drift and
  // is pushed along its new heading across the whole window, so it reads as the car
  // straightening up and driving out rather than as a snap.
  updateExitFlick(dt) {
    if (this.exitFlickRemaining <= 0) return

    const s = this.spec.slide
    const angular = this.body.angvel(this._angular)
    this.body.setAngvel(
      { x: angular.x, y: this.exitDirection * (s.exit_angle / s.exit_time), z: angular.z },
      true
    )

    const v = this.body.linvel(this._vec)
    const push = (s.exit_kick_speed / s.exit_time) * dt
    this.body.setLinvel({
      x: v.x + this._forward.x * push,
      y: v.y,
      z: v.z + this._forward.z * push
    }, true)

    this.exitFlickRemaining -= dt
  }

  applyDriftGrip() {
    const s = this.spec.slide

    this.spec.wheels.forEach((wheel, i) => {
      if (!this.drifting) {
        this.controller.setWheelSideFrictionStiffness(i, wheel.side_friction_stiffness)
        return
      }
      // The rear lets go; the front keeps enough bite to still point the car.
      const scale = wheel.slides ? s.rear_friction_scale : s.front_friction_scale
      this.controller.setWheelSideFrictionStiffness(i, wheel.side_friction_stiffness * scale)
    })
  }

  // Braking into a corner should tighten the line, not merely slow the car. Steering
  // angle alone cannot do it -- the front tyres saturate -- so the weight transfer is
  // modelled directly as a yaw assist proportional to brake, steering and speed.
  //
  // Drifting has its own arc control, so this stays out of its way.
  updateTrailBraking(dt, input, grounded, speed) {
    if (this.drifting || grounded === 0) return
    if (input.brake <= 0.05 || Math.abs(input.steer) < 0.05) return
    if (Math.abs(speed) < 2) return

    const s = this.spec.steering
    const load = Math.min(Math.abs(speed) / this.spec.engine.top_speed, 1)
    const amount = input.brake * Math.abs(input.steer) * load
    const direction = Math.sign(input.steer)

    // Negative rotation about +Y turns to the driver's right.
    this._torque.copy(this._up).multiplyScalar(-direction * s.brake_yaw_assist * amount * dt)
    this.body.applyTorqueImpulse(this._torque, true)
  }

  // airRoll/airPitch record the torque that was actually applied, and are what the booster
  // flames read. Every gate below -- grounded, sliding, spun out -- can leave the stick
  // hard over while nothing at all happens to the chassis, so a view deriving tilt from
  // raw input would light boosters for a roll the truck is not performing.
  updateAirControl(dt, input, grounded) {
    this.airRoll = 0
    this.airPitch = 0

    if (grounded > 0) return
    // While the slide button is held, steering means "set up a drift", not "bank the
    // car". Without this the hop and the air roll fight each other and it flips.
    if (input.slide) return

    const ac = this.spec.air_control
    const angular = this.body.angvel(this._vec)
    const spin = Math.hypot(angular.x, angular.y, angular.z)
    if (spin >= ac.max_angular_speed) return

    // Steering in the air shifts weight left/right: roll about the chassis forward axis.
    // Positive rotation about +Z lifts the driver's left side, i.e. banks right.
    if (input.steer !== 0) {
      this._torque.copy(this._forward).multiplyScalar(input.steer * ac.roll_torque * dt)
      this.body.applyTorqueImpulse(this._torque, true)
      this.airRoll = input.steer
    }

    // Pitch comes from its own stick axis, never from the pedals: throttle and brake
    // should not tip the car over mid-jump.
    if (input.pitch !== 0) {
      // _right is -X, so a negative rotation about it drops the nose.
      this._torque.copy(this._right).multiplyScalar(-input.pitch * ac.pitch_torque * dt)
      this.body.applyTorqueImpulse(this._torque, true)
      this.airPitch = input.pitch
    }
  }

  updateFlipRecovery(dt, input, speed) {
    // Slide is also the righting button when you land on your roof.
    if (!input.slide) return

    const fr = this.spec.flip_recovery
    if (this._up.y > fr.up_dot_threshold) return
    if (Math.abs(speed) > fr.max_speed) return

    // Rotate the chassis up-vector back toward world up.
    this._torque.copy(this._up).cross(WORLD_UP)
    // Exactly inverted gives a degenerate axis; roll about forward instead.
    if (this._torque.lengthSq() < 1e-4) this._torque.copy(this._forward)
    this._torque.normalize().multiplyScalar(fr.torque * dt)
    this.body.applyTorqueImpulse(this._torque, true)
  }

  // Everything a conditional part needs to decide whether its bonus applies. It lives on
  // the vehicle because the vehicle owns every field in it, and because the resolver, the
  // overlay and the bull bar's own collider all have to reach the same answer.
  damageState() {
    return {
      drifting: this.drifting,
      slip_angle: this.slipAngle(),
      drift_grace: this.driftGrace,
      slamming: this.slamming,
      fall_speed: this.body.linvel(this._vec).y
    }
  }

  // Swung out for as long as the slide lasts, and through the retain window after it, so
  // the box and the lingering bonus go away together.
  //
  // The gate is the slide itself rather than the bar being armed. Slip angle hovers right
  // around the arming threshold for most of a drift, so gating on that pumped the box
  // fully in and out several times a corner -- and with nothing drawn to explain it, the
  // bar would simply have missed for no visible reason.
  //
  // Eased rather than snapped: a solid collider appearing at full size inside a prop it
  // already overlaps fires the thing across the arena.
  //
  // Growing further back than forward means MOVING the box as well as resizing it --
  // a cuboid is symmetric about its own offset, so asymmetric reach has nowhere else to
  // come from.
  updateBullBar(dt) {
    const bar = this.bullBar
    if (!bar) return

    const step = bar.easeTime > 0 ? dt / bar.easeTime : 1
    const wanted = this.drifting || this.driftGrace > 0 ? step : -step
    const amount = Math.min(Math.max(bar.amount + wanted, 0), 1)
    // Rapier rebuilds the shape on every setHalfExtents, so skip the frames that would
    // rewrite the same box.
    if (amount === bar.amount) return
    bar.amount = amount

    const { resting, reaching } = bar
    bar.collider.setHalfExtents({
      x: lerp(resting.half.x, reaching.half.x, amount),
      y: lerp(resting.half.y, reaching.half.y, amount),
      z: lerp(resting.half.z, reaching.half.z, amount)
    })
    bar.collider.setTranslationWrtParent({
      x: lerp(resting.at.x, reaching.at.x, amount),
      y: lerp(resting.at.y, reaching.at.y, amount),
      z: lerp(resting.at.z, reaching.at.z, amount)
    })
    bar.collider.setCollisionGroups(amount > 0 ? bar.reachingGroups : bar.restingGroups)
  }

  // Read back out of Rapier rather than from what we meant to set: the overlay and the
  // tests should see the box the physics actually has. Rapier exposes no getter for a
  // collider's local offset, so it is recovered by projecting the collider's world
  // position onto the chassis forward axis -- which is exactly its local z, the basis
  // being orthonormal.
  bullBarBox() {
    const bar = this.bullBar
    if (!bar) return null

    const half = bar.collider.halfExtents()
    const at = bar.collider.translation()
    const origin = this.body.translation()

    return {
      halfWidth: half.x,
      halfHeight: half.y,
      halfDepth: half.z,
      z: (at.x - origin.x) * this._forward.x +
         (at.y - origin.y) * this._forward.y +
         (at.z - origin.z) * this._forward.z,
      hitsWorld: catchesWorld(bar.collider.collisionGroups())
    }
  }

  // Overridden by the subclasses: jets for the truck, rockets for the buggy.
  updateAction(dt, input, grounded) {}

  respawn(spawn) {
    const target = spawn || this.spawn
    const [x, y, z] = target.position
    const half = (target.yaw || 0) / 2

    this.body.setTranslation({ x, y, z }, true)
    this.body.setRotation({ x: 0, y: Math.sin(half), z: 0, w: Math.cos(half) }, true)
    this.body.setLinvel({ x: 0, y: 0, z: 0 }, true)
    this.body.setAngvel({ x: 0, y: 0, z: 0 }, true)
    this.turboBar.level = this.turboBar.capacity
    this.drifting = false
    this.boostTime = 0
    this.exitFlickRemaining = 0
  }

  // Debug/test helper: park the vehicle at a known position and heading.
  placeAt({ x, y, z, yaw }) {
    const half = (yaw || 0) / 2
    this.body.setTranslation({ x, y, z }, true)
    this.body.setRotation({ x: 0, y: Math.sin(half), z: 0, w: Math.cos(half) }, true)
    this.body.setLinvel({ x: 0, y: 0, z: 0 }, true)
    this.body.setAngvel({ x: 0, y: 0, z: 0 }, true)
  }

  // Debug/test helper: park the vehicle on its roof.
  invert() {
    const t = this.body.translation(this._vec)
    this.body.setTranslation({ x: t.x, y: t.y + 1.5, z: t.z }, true)
    this.body.setRotation({ x: 0, y: 0, z: 1, w: 0 }, true)
    this.body.setLinvel({ x: 0, y: 0, z: 0 }, true)
    this.body.setAngvel({ x: 0, y: 0, z: 0 }, true)
  }

  retune() {
    this.spec.wheels.forEach((wheel, i) => applyWheelTuning(this.controller, i, wheel))
  }
}
