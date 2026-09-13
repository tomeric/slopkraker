import * as THREE from "three"
import { DEBRIS_GROUPS } from "game/physics/groups"

// Props take damage and, past zero health, break into debris. Not buildings -- just
// enough to feel the blade, the bull bar and a rocket actually land.
export class Destruction {
  constructor({ RAPIER, world, scene, colliderIndex, onBreak, minimumFraction = 0 }) {
    this.minimumFraction = minimumFraction
    this.RAPIER = RAPIER
    this.world = world
    this.scene = scene
    this.colliderIndex = colliderIndex
    this.onBreak = onBreak || (() => {})
    this.debris = []
  }

  apply(prop, damage) {
    if (prop.broken || damage <= 0) return 0

    // A prop shrugs off its hardness the same way a material does, and the same floor
    // applies: a fraction always lands, so nothing is quietly invincible.
    const hardness = prop.spec.hardness || 0
    prop.health -= Math.max(damage - hardness, damage * this.minimumFraction)
    const mesh = prop.mesh
    if (mesh) {
      // Darken toward black as it takes damage, so hits read before it breaks.
      const ratio = Math.max(prop.health / prop.spec.health, 0)
      mesh.material.color.setStyle(prop.spec.colour)
      mesh.material.color.multiplyScalar(0.35 + 0.65 * ratio)
    }

    if (prop.health <= 0) this.break(prop)
    return damage
  }

  break(prop) {
    prop.broken = true
    this.onBreak(prop)

    const translation = prop.body.translation()
    const rotation = prop.body.rotation()
    const velocity = prop.body.linvel()

    // Read the handle BEFORE the body goes: the collider wrapper reaches into the wasm
    // heap, and touching it afterwards is a use-after-free.
    this.colliderIndex.delete(prop.collider.handle)
    this.world.removeRigidBody(prop.body)
    prop.mesh?.removeFromParent()

    this.spawnDebris(prop, translation, rotation, velocity)
  }

  spawnDebris(prop, translation, rotation, velocity) {
    const [w, h, d] = prop.spec.size
    const count = prop.spec.debris_count
    // Split along the longest axis so a pillar shatters into stacked chunks and a crate
    // into a cluster.
    const perSide = Math.max(Math.round(Math.cbrt(count)), 2)
    const size = [w / perSide, h / perSide, d / perSide]
    const mass = prop.spec.mass / (perSide ** 3)

    const geometry = new THREE.BoxGeometry(size[0], size[1], size[2])
    const material = new THREE.MeshStandardMaterial({ color: prop.spec.colour, roughness: 0.85 })

    for (let ix = 0; ix < perSide; ix += 1) {
      for (let iy = 0; iy < perSide; iy += 1) {
        for (let iz = 0; iz < perSide; iz += 1) {
          const offset = {
            x: (ix - (perSide - 1) / 2) * size[0],
            y: (iy - (perSide - 1) / 2) * size[1],
            z: (iz - (perSide - 1) / 2) * size[2]
          }
          this.spawnChunk(geometry, material, size, mass, translation, rotation, velocity, offset)
        }
      }
    }
  }

  spawnChunk(geometry, material, size, mass, translation, rotation, velocity, offset) {
    const RAPIER = this.RAPIER
    const body = this.world.createRigidBody(
      RAPIER.RigidBodyDesc.dynamic()
        .setTranslation(translation.x + offset.x, translation.y + offset.y, translation.z + offset.z)
        .setRotation(rotation)
        .setLinvel(
          velocity.x + (Math.random() - 0.5) * 4,
          velocity.y + Math.random() * 3.5,
          velocity.z + (Math.random() - 0.5) * 4
        )
        .setAngvel({ x: rand(6), y: rand(6), z: rand(6) })
        .setLinearDamping(0.2)
        .setAngularDamping(0.4)
    )
    this.world.createCollider(
      RAPIER.ColliderDesc.cuboid(size[0] / 2, size[1] / 2, size[2] / 2)
        .setMass(mass)
        .setCollisionGroups(DEBRIS_GROUPS)
        .setFriction(0.7)
        .setRestitution(0.15),
      body
    )

    const mesh = new THREE.Mesh(geometry, material)
    mesh.castShadow = true
    this.scene.add(mesh)

    this.debris.push({ body, mesh, life: 0 })
  }

  // Debris is cosmetic; retiring it keeps the step cost from creeping up over a session.
  update(dt, maxLife = 12) {
    for (let i = this.debris.length - 1; i >= 0; i -= 1) {
      const chunk = this.debris[i]
      chunk.life += dt
      if (chunk.life < maxLife) continue

      this.world.removeRigidBody(chunk.body)
      chunk.mesh.removeFromParent()
      this.debris.splice(i, 1)
    }
  }

  sync() {
    for (const chunk of this.debris) {
      const t = chunk.body.translation()
      const r = chunk.body.rotation()
      chunk.mesh.position.set(t.x, t.y, t.z)
      chunk.mesh.quaternion.set(r.x, r.y, r.z, r.w)
    }
  }

  dispose() {
    for (const chunk of this.debris) chunk.mesh.removeFromParent()
    this.debris = []
  }
}

function rand(scale) {
  return (Math.random() - 0.5) * scale
}
