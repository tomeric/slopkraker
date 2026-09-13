import * as THREE from "three"
import { Vehicle } from "game/vehicles/vehicle"

// Action key fires a rocket from the launcher muzzle in a shallow upward arc, inheriting
// the buggy's own velocity. The turbo bar is the ammo supply.
export class Buggy extends Vehicle {
  constructor(options) {
    super(options)
    this.projectiles = options.projectiles
    this.launcher = this.spec.parts.find((part) => part.kind === "rocket_launcher")
    this.sinceFired = Infinity

    this._muzzle = new THREE.Vector3()
    this._direction = new THREE.Vector3()
    this._inherited = { x: 0, y: 0, z: 0 }
  }

  updateAction(dt, input) {
    this.sinceFired += dt
    if (!input.action || !this.launcher || !this.projectiles) return
    if (this.sinceFired < this.launcher.cooldown) return
    if (!this.turboBar.draw(this.launcher.ammo_cost)) return

    this.sinceFired = 0
    this.fire()
  }

  fire() {
    const offset = this.launcher.offset
    const translation = this.body.translation()

    this._muzzle
      .set(offset[0], offset[1], offset[2] + this.launcher.size[2] / 2)
      .applyQuaternion(this._quat)
      .add(new THREE.Vector3(translation.x, translation.y, translation.z))

    // Chassis forward, pitched up by the launch angle about the chassis right axis.
    // _right is -X, so a positive rotation about it raises the nose.
    const radians = (this.launcher.launch_angle * Math.PI) / 180
    this._direction.copy(this._forward).applyAxisAngle(this._right, radians).normalize()

    const velocity = this.body.linvel()
    this._inherited.x = velocity.x
    this._inherited.y = velocity.y
    this._inherited.z = velocity.z

    this.projectiles.spawn({
      spec: this.launcher.rocket,
      position: this._muzzle,
      direction: this._direction,
      inheritedVelocity: this._inherited,
      owner: "local"
    })
  }
}
