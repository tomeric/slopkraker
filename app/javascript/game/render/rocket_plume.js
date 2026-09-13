import * as THREE from "three"

// How many puffs one rocket can have hanging in the air at once, and how long each lasts.
// A ring buffer rather than spawn-and-destroy: a rocket at 64 m/s would otherwise churn
// through a mesh every frame.
const PUFFS = 20
const PUFF_LIFE = 0.45
// Dense under power, a thin wisp while it is coasting -- so the trail thickens at exactly
// the moment the motor catches.
const DROP_THRUST = 0.012
const DROP_COAST = 0.05

// Exhaust for a single rocket, in plain primitives: this project ships no texture assets.
//
// The flame burns only during the thrust phase, which makes ignition something you watch
// rather than something you infer from the trajectory.
export class RocketPlume {
  constructor(scene, rocketMesh, spec) {
    this.scene = scene

    this.flameGeometry = new THREE.ConeGeometry(spec.radius * 1.9, spec.radius * 11, 12)
    // The cone points up its own +Y and the rocket travels down +Z, so a quarter turn
    // back about X aims the flame out of the tail.
    this.flameGeometry.rotateX(-Math.PI / 2)
    this.flame = new THREE.Mesh(
      this.flameGeometry,
      new THREE.MeshBasicMaterial({
        color: "#ffd066",
        transparent: true,
        opacity: 1,
        depthWrite: false,
        blending: THREE.AdditiveBlending
      })
    )
    // Parented to the rocket, so it inherits the nose-over through the arc for free.
    this.flame.position.z = -(spec.radius * 5.5 + 0.45)
    this.flame.visible = false
    rocketMesh.add(this.flame)

    this.puffGeometry = new THREE.SphereGeometry(spec.radius * 1.7, 8, 6)
    this.puffs = Array.from({ length: PUFFS }, () => {
      const mesh = new THREE.Mesh(
        this.puffGeometry,
        new THREE.MeshBasicMaterial({
          color: "#ff9a3c",
          transparent: true,
          opacity: 0,
          depthWrite: false,
          blending: THREE.AdditiveBlending
        })
      )
      mesh.visible = false
      scene.add(mesh)
      return { mesh, age: Infinity, thrusting: false }
    })

    this.next = 0
    this.sinceDrop = 0
  }

  update(dt, position, thrusting) {
    this.flame.visible = thrusting
    if (thrusting) {
      // Flickered every frame, or it reads as a cone glued to the back rather than as
      // something burning.
      this.flame.scale.z = 0.75 + Math.random() * 0.5
      this.flame.material.opacity = 0.8 + Math.random() * 0.2
    }

    this.sinceDrop += dt
    if (this.sinceDrop >= (thrusting ? DROP_THRUST : DROP_COAST)) {
      this.sinceDrop = 0
      const puff = this.puffs[this.next]
      this.next = (this.next + 1) % this.puffs.length
      puff.mesh.position.copy(position)
      puff.age = 0
      puff.thrusting = thrusting
    }

    for (const puff of this.puffs) {
      if (puff.age === Infinity) continue

      puff.age += dt
      const t = puff.age / PUFF_LIFE
      if (t >= 1) {
        puff.mesh.visible = false
        puff.age = Infinity
        continue
      }

      // Billowing out and thinning as it goes, and half the size when it came off a
      // rocket that was only coasting.
      const scale = puff.thrusting ? 1 : 0.5
      puff.mesh.visible = true
      puff.mesh.scale.setScalar((0.5 + t * 2.2) * scale)
      puff.mesh.material.opacity = (1 - t) * 0.75 * scale
    }
  }

  dispose() {
    this.flame.removeFromParent()
    this.flame.material.dispose()
    this.flameGeometry.dispose()

    for (const puff of this.puffs) {
      puff.mesh.removeFromParent()
      puff.mesh.material.dispose()
    }
    this.puffGeometry.dispose()
    this.puffs = []
  }
}
