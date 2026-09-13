import { Vehicle } from "game/vehicles/vehicle"

// Action fires the jump jets. Thrust runs along the CHASSIS up-axis rather than world up,
// so the driver can aim the burn by rotating the truck.
//
// Slide, while airborne, is the same thruster pointed the other way: it drives the truck
// into the ground, ramping the longer it is held, and the underside plate does heavy
// damage to whatever is beneath.
export class MonsterTruck extends Vehicle {
  constructor(options) {
    super(options)
    this.jets = this.spec.parts.find((part) => part.kind === "jump_jets")
    this.jetThrottle = 0
    this.airTime = 0
    this.slamThrust = 0
  }

  // What the boosters render. Kept here rather than in the view so the flames can only
  // ever show thrust the truck is actually producing.
  boosterState() {
    const max = this.spec.slam?.max_thrust || 0
    return {
      lift: this.jetThrottle,
      slam: max > 0 ? this.slamThrust / max : 0,
      roll: this.airRoll,
      pitch: this.airPitch
    }
  }

  updateAction(dt, input, grounded) {
    // Slam first: the thruster cannot point both ways at once, so committing to a slam
    // cuts the jets rather than fighting them to a standstill.
    this.updateSlam(dt, input, grounded)
    this.updateJets(dt, input)
  }

  updateJets(dt, input) {
    this.jetThrottle = 0
    if (this.slamming) return
    if (!input.action || !this.jets) return
    if (!this.turboBar.draw(this.jets.drain_rate * dt)) return

    this.jetThrottle = 1
    // An impulse of force*dt is equivalent to a continuous force, and avoids Rapier's
    // addForce persisting across steps until explicitly reset.
    this._torque.copy(this._up).multiplyScalar(this.jets.thrust * dt)
    this.body.applyImpulse(this._torque, true)
  }

  updateSlam(dt, input, grounded) {
    const slam = this.spec.slam
    this.airTime = grounded > 0 ? 0 : this.airTime + dt

    // Only in the air, only once properly off the ground (engaging instantly would turn
    // the drift hop into an immediate slam back into the floor), and only while roughly
    // upright -- otherwise Slide would slam the roof down instead of righting the truck,
    // and flip recovery shares this button.
    const upright = this._up.y > 0.3

    if (!slam || grounded > 0 || !input.slide || !upright || this.airTime < slam.engage_delay) {
      this.slamming = false
      this.slamTime = 0
      this.slamThrust = 0
      return
    }

    this.slamTime += dt
    // Ramps with how long it is held, so committing early lands harder.
    const thrust = Math.min(slam.initial_thrust + slam.ramp * this.slamTime, slam.max_thrust)

    this._torque.copy(this._up).multiplyScalar(-thrust * dt)
    this.body.applyImpulse(this._torque, true)
    this.slamming = true
    // Kept so the roof booster can ramp with the hold; nothing else reads it.
    this.slamThrust = thrust
  }
}
