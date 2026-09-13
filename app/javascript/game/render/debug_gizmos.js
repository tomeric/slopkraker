import * as THREE from "three"

const ARC_SAMPLES = 30
const ARC_STEP = 0.055

// In-canvas development view. The slide arc is the useful one: it integrates the current
// planar velocity against the current yaw rate, so it draws the path the car is actually
// on right now. If the arc does not bend into the corner, the drift is not working --
// which is far easier to see than to infer from numbers.
export class DebugGizmos {
  constructor(scene) {
    this.scene = scene
    this.visible = true

    this.group = new THREE.Group()
    this.group.name = "debug"
    scene.add(this.group)

    this.velocity = this.arrow("#5ad16b")
    this.heading = this.arrow("#5aa8ff")

    this.arcPositions = new Float32Array((ARC_SAMPLES + 1) * 3)
    const geometry = new THREE.BufferGeometry()
    geometry.setAttribute("position", new THREE.BufferAttribute(this.arcPositions, 3))
    this.arcMaterial = new THREE.LineBasicMaterial({ color: "#f2c014", transparent: true, opacity: 0.85 })
    this.arc = new THREE.Line(geometry, this.arcMaterial)
    this.arc.frustumCulled = false
    this.group.add(this.arc)

    this.contacts = []
    for (let i = 0; i < 4; i += 1) {
      const dot = new THREE.Mesh(
        new THREE.SphereGeometry(0.13, 8, 6),
        new THREE.MeshBasicMaterial({ color: "#ff5a1f" })
      )
      dot.visible = false
      this.group.add(dot)
      this.contacts.push(dot)
    }

    this._v = new THREE.Vector3()
    this._origin = new THREE.Vector3()
    this._contact = { x: 0, y: 0, z: 0 }
  }

  arrow(colour) {
    const helper = new THREE.ArrowHelper(
      new THREE.Vector3(0, 0, 1), new THREE.Vector3(), 3, new THREE.Color(colour), 0.7, 0.35
    )
    this.group.add(helper)
    return helper
  }

  toggle() {
    this.visible = !this.visible
    this.group.visible = this.visible
  }

  update(vehicle, position) {
    if (!this.visible || !vehicle) return

    const origin = this._origin.copy(position)
    origin.y += 0.6

    const velocity = vehicle.body.linvel()
    const planar = Math.hypot(velocity.x, velocity.z)

    this.velocity.position.copy(origin)
    if (planar > 0.4) {
      this.velocity.setDirection(this._v.set(velocity.x, 0, velocity.z).normalize())
      this.velocity.setLength(Math.min(1 + planar * 0.22, 9), 0.7, 0.35)
      this.velocity.visible = true
    } else {
      this.velocity.visible = false
    }

    this.heading.position.copy(origin)
    this.heading.setDirection(this._v.copy(vehicle._forward).setY(0).normalize())
    this.heading.setLength(3.2, 0.6, 0.3)

    this.updateArc(vehicle, position, velocity)
    this.updateContacts(vehicle)
  }

  // Forward-integrate the planar velocity while rotating it by the current yaw rate.
  // A straight line means no rotation; a tight curl means the car is rotating hard
  // relative to how fast it is travelling.
  updateArc(vehicle, position, velocity) {
    const yawRate = vehicle.body.angvel().y
    let x = position.x
    let z = position.z
    let vx = velocity.x
    let vz = velocity.z

    const theta = yawRate * ARC_STEP
    const cos = Math.cos(theta)
    const sin = Math.sin(theta)

    for (let i = 0; i <= ARC_SAMPLES; i += 1) {
      const base = i * 3
      this.arcPositions[base] = x
      this.arcPositions[base + 1] = position.y - 0.25
      this.arcPositions[base + 2] = z

      x += vx * ARC_STEP
      z += vz * ARC_STEP

      const nextX = vx * cos + vz * sin
      const nextZ = -vx * sin + vz * cos
      vx = nextX
      vz = nextZ
    }

    this.arc.geometry.attributes.position.needsUpdate = true
    this.arc.geometry.computeBoundingSphere()

    // Bright while drifting, dim otherwise -- the arc doubles as a drift indicator.
    this.arcMaterial.color.set(vehicle.drifting ? "#ff8a1f" : "#f2c014")
    this.arcMaterial.opacity = vehicle.drifting ? 1 : 0.4
  }

  updateContacts(vehicle) {
    for (let i = 0; i < this.contacts.length; i += 1) {
      const dot = this.contacts[i]
      if (i >= vehicle.wheelCount || !vehicle.controller.wheelIsInContact(i)) {
        dot.visible = false
        continue
      }
      const point = vehicle.controller.wheelContactPoint(i, this._contact)
      if (!point) {
        dot.visible = false
        continue
      }
      dot.position.set(point.x, point.y + 0.05, point.z)
      dot.visible = true
    }
  }

  dispose() {
    this.group.removeFromParent()
  }
}
