import * as THREE from "three"

// Meshes built from the Ruby spec. Wheel transforms are read straight from Rapier each
// render frame -- never interpolated, because suspension travel and steering angle are
// exactly what the player reads as responsiveness.
export class VehicleView {
  constructor(scene, spec) {
    this.spec = spec
    this.group = new THREE.Group()
    this.group.name = `vehicle:${spec.key}`

    const [cw, ch, cl] = spec.chassis.size
    this.chassis = new THREE.Mesh(
      new THREE.BoxGeometry(cw, ch, cl),
      new THREE.MeshStandardMaterial({ color: spec.chassis.colour, roughness: 0.45, metalness: 0.25 })
    )
    this.chassis.castShadow = true
    this.chassis.receiveShadow = true
    this.group.add(this.chassis)

    // A nose marker: with primitive geometry it is otherwise genuinely hard to tell
    // which way the vehicle is pointing while airborne.
    const nose = new THREE.Mesh(
      new THREE.BoxGeometry(cw * 0.28, ch * 0.3, cl * 0.08),
      new THREE.MeshStandardMaterial({ color: "#0e1116", roughness: 0.6 })
    )
    nose.position.set(0, ch * 0.42, cl * 0.42)
    this.group.add(nose)

    this.parts = spec.parts.map((part) => this.buildPart(part))
    this.wheels = spec.wheels.map((wheel) => this.buildWheel(wheel))

    scene.add(this.group)
  }

  buildPart(part) {
    const [w, h, d] = part.size
    const colour = part.kind === "jump_jets" ? "#3b4554" : "#cfd6de"
    const mesh = new THREE.Mesh(
      new THREE.BoxGeometry(w, h, d),
      new THREE.MeshStandardMaterial({ color: colour, roughness: 0.35, metalness: 0.6 })
    )
    const [x, y, z] = part.offset
    mesh.position.set(x, y, z)
    mesh.castShadow = true
    mesh.name = part.name
    this.group.add(mesh)
    return { part, mesh }
  }

  buildWheel(wheel) {
    // CylinderGeometry is Y-aligned; bake a quarter turn so the axle runs along X.
    const geometry = new THREE.CylinderGeometry(wheel.radius, wheel.radius, wheel.width, 18)
    geometry.rotateZ(Math.PI / 2)

    const mesh = new THREE.Mesh(
      geometry,
      new THREE.MeshStandardMaterial({ color: "#1b1f25", roughness: 0.85 })
    )
    mesh.castShadow = true
    mesh.name = wheel.name

    // A spoke so wheel spin is actually visible on a plain dark cylinder.
    const spoke = new THREE.Mesh(
      new THREE.BoxGeometry(wheel.width * 1.05, wheel.radius * 1.7, wheel.radius * 0.28),
      new THREE.MeshStandardMaterial({ color: "#aab3bf", roughness: 0.5, metalness: 0.4 })
    )
    mesh.add(spoke)

    this.group.add(mesh)
    return { wheel, mesh }
  }

  syncWheels(controller) {
    this._anchor ||= { x: 0, y: 0, z: 0 }
    this._steerQuat ||= new THREE.Quaternion()
    this._spinQuat ||= new THREE.Quaternion()
    this._axisY ||= new THREE.Vector3(0, 1, 0)
    this._axisX ||= new THREE.Vector3(1, 0, 0)

    this.wheels.forEach((entry, i) => {
      const anchor = controller.wheelChassisConnectionPointCs(i, this._anchor)
      const suspension = controller.wheelSuspensionLength(i)
      if (!anchor || suspension === null) return

      entry.mesh.position.set(anchor.x, anchor.y - suspension, anchor.z)

      this._steerQuat.setFromAxisAngle(this._axisY, controller.wheelSteering(i) || 0)
      this._spinQuat.setFromAxisAngle(this._axisX, controller.wheelRotation(i) || 0)
      entry.mesh.quaternion.copy(this._steerQuat).multiply(this._spinQuat)
    })
  }

  setTransform(position, quaternion) {
    this.group.position.copy(position)
    this.group.quaternion.copy(quaternion)
  }

  dispose() {
    this.group.removeFromParent()
  }
}
