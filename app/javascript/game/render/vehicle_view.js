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
    const material = new THREE.MeshStandardMaterial({ color: colour, roughness: 0.35, metalness: 0.6 })
    const bar = part.spikes ? spikedBar(part, material) : null
    const mesh = bar ? bar.group : new THREE.Mesh(new THREE.BoxGeometry(w, h, d), material)

    const [x, y, z] = part.offset
    mesh.position.set(x, y, z)
    mesh.name = part.name
    // traverse rather than a bare assignment: a spiked bar is a group, and castShadow on
    // a group is ignored.
    mesh.traverse((node) => { node.castShadow = true })
    this.group.add(mesh)
    return { part, mesh, bar }
  }

  // The bull bar's hitbox swings out while the car is sliding. The spikes telescope out
  // with it, to exactly the reach the collider has, so the bar you can see is the bar you
  // are actually swinging -- otherwise the extra reach is an invisible rule.
  //
  // The solid section is left alone and the spikes do all the travelling: they grow out of
  // the bar rather than the whole bar stretching.
  syncBullBar(live) {
    const entry = this.parts.find(({ bar }) => bar)
    if (!entry || !live) return

    const { bar } = entry
    const length = Math.max(live.halfWidth - bar.width / 2, 0)

    for (const { mesh, side } of bar.spikes) {
      // The cone was built along +Y and turned a quarter circle, so its own Y is the
      // direction it points.
      mesh.scale.y = length / bar.spikeLength
      mesh.position.x = side * (bar.width / 2 + length / 2)
    }

    bar.box.scale.z = (live.halfDepth * 2) / bar.depth
    entry.mesh.position.z = live.z
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

// The bar plus a tapered spike at each end, drawn to the same total width the collider
// has: Ruby narrows the solid section by exactly what the spikes add back on, so what you
// see is what the hitbox covers.
//
// ConeGeometry points up the +Y axis with its apex at the top, so a quarter turn about Z
// aims it out along the bar -- negative for the driver's right (+X), positive for the left.
function spikedBar(part, material) {
  const [, h, d] = part.size
  const { length, radius, bar_width: width } = part.spikes

  const group = new THREE.Group()
  const box = new THREE.Mesh(new THREE.BoxGeometry(width, h, d), material)
  group.add(box)

  const spikes = [ -1, 1 ].map((side) => {
    const mesh = new THREE.Mesh(new THREE.ConeGeometry(radius, length, 12), material)
    mesh.rotation.z = (-side * Math.PI) / 2
    mesh.position.x = side * (width / 2 + length / 2)
    group.add(mesh)
    return { mesh, side }
  })

  // The resting dimensions are kept so syncBullBar can scale against them rather than
  // against whatever it left behind last frame.
  return { group, box, spikes, width, depth: d, spikeLength: length }
}
