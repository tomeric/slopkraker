import * as THREE from "three"
import { rocketGroups } from "game/physics/groups"
import { rocketDamage } from "game/damage"
import { createLabel, drawLabel, disposeLabel, wireBox, ARMED_COLOUR } from "game/render/gizmo_label"

// Rockets leave the rail slowly and wind up under their own thrust, so a shot with room
// to run lands far harder than one fired point blank. They detonate on contact or when
// their lifetime runs out, and carry whatever damage their speed was worth at that moment.
//
// With the debug overlay on, each live rocket wears its own hitbox and damage readout.
export class Projectiles {
  constructor({ RAPIER, world, scene, colliderIndex, onDetonate }) {
    this.RAPIER = RAPIER
    this.world = world
    this.scene = scene
    this.colliderIndex = colliderIndex
    this.onDetonate = onDetonate || (() => {})
    this.live = []
    this.fired = 0
    this.debugVisible = true

    this.geometry = new THREE.CapsuleGeometry(0.16, 0.5, 4, 8)
    this.geometry.rotateX(Math.PI / 2)
  }

  spawn({ spec, position, direction, inheritedVelocity, owner }) {
    const RAPIER = this.RAPIER

    const body = this.world.createRigidBody(
      RAPIER.RigidBodyDesc.dynamic()
        .setTranslation(position.x, position.y, position.z)
        .setLinvel(
          inheritedVelocity.x + direction.x * spec.launch_speed,
          inheritedVelocity.y + direction.y * spec.launch_speed,
          inheritedVelocity.z + direction.z * spec.launch_speed
        )
        .setGravityScale(spec.gravity_scale)
        .setCcdEnabled(true)
        .setAngularDamping(4)
    )

    const collider = this.world.createCollider(
      RAPIER.ColliderDesc.ball(spec.radius)
        .setMass(spec.mass)
        .setCollisionGroups(rocketGroups(owner))
        .setRestitution(0)
        .setActiveEvents(RAPIER.ActiveEvents.COLLISION_EVENTS),
      body
    )

    const mesh = new THREE.Mesh(
      this.geometry,
      new THREE.MeshStandardMaterial({
        color: spec.colour, emissive: spec.colour, emissiveIntensity: 0.7, roughness: 0.4
      })
    )
    mesh.castShadow = true
    this.scene.add(mesh)

    const rocket = {
      spec, body, collider, mesh, life: 0, owner, dead: false,
      damage: rocketDamage(spec, spec.launch_speed),
      ...this.buildGizmo(spec)
    }

    this.colliderIndex.set(collider.handle, {
      kind: "rocket", name: "rocket", part: null, owner, rocket
    })
    this.live.push(rocket)
    this.fired += 1
    return rocket
  }

  buildGizmo(spec) {
    const extent = spec.radius * 2
    const box = wireBox([ extent, extent, extent + 0.5 ], ARMED_COLOUR)
    box.visible = this.debugVisible
    this.scene.add(box)

    const label = createLabel({ scale: [ 1.3, 0.65 ] })
    label.sprite.visible = this.debugVisible
    this.scene.add(label.sprite)

    return { box, label }
  }

  update(dt) {
    for (let i = this.live.length - 1; i >= 0; i -= 1) {
      const rocket = this.live[i]
      rocket.life += dt

      if (rocket.dead || rocket.life >= rocket.spec.lifetime) {
        this.detonate(rocket)
        this.live.splice(i, 1)
        continue
      }

      this.accelerate(rocket, dt)
    }
  }

  // Thrust along its own heading, capped at the spec's top speed.
  accelerate(rocket, dt) {
    const spec = rocket.spec
    const v = rocket.body.linvel()
    const speed = Math.hypot(v.x, v.y, v.z)
    if (speed < 0.01) return

    const target = Math.min(speed + spec.acceleration * dt, spec.max_speed)
    const scale = target / speed
    rocket.body.setLinvel({ x: v.x * scale, y: v.y * scale, z: v.z * scale }, true)

    rocket.damage = rocketDamage(spec, target)
    rocket.speed = target
  }

  markDead(rocket) {
    rocket.dead = true
  }

  detonate(rocket) {
    const t = rocket.body.translation()
    const at = new THREE.Vector3(t.x, t.y, t.z)

    this.colliderIndex.delete(rocket.collider.handle)
    this.world.removeRigidBody(rocket.body)
    rocket.mesh.removeFromParent()
    rocket.box.removeFromParent()
    rocket.label.sprite.removeFromParent()
    disposeLabel(rocket.label)

    // The blast is worth what the rocket was worth when it landed.
    this.onDetonate(at, rocket.spec, rocket.damage)
  }

  sync() {
    for (const rocket of this.live) {
      const t = rocket.body.translation()
      rocket.mesh.position.set(t.x, t.y, t.z)

      // Point the rocket along its own velocity so it noses over through the arc.
      const v = rocket.body.linvel()
      if (v.x || v.y || v.z) rocket.mesh.lookAt(t.x + v.x, t.y + v.y, t.z + v.z)

      rocket.box.visible = this.debugVisible
      rocket.label.sprite.visible = this.debugVisible
      if (!this.debugVisible) continue

      rocket.box.position.copy(rocket.mesh.position)
      rocket.box.quaternion.copy(rocket.mesh.quaternion)
      rocket.label.sprite.position.set(t.x, t.y + 0.9, t.z)

      drawLabel(rocket.label, {
        title: "ROCKET",
        value: Math.round(rocket.damage),
        footer: `${Math.round(rocket.speed || rocket.spec.launch_speed)} m/s`,
        armed: true
      })
    }
  }

  dispose() {
    for (const rocket of this.live) {
      this.world.removeRigidBody(rocket.body)
      rocket.mesh.removeFromParent()
      rocket.box.removeFromParent()
      rocket.label.sprite.removeFromParent()
      disposeLabel(rocket.label)
    }
    this.live = []
    this.geometry.dispose()
  }
}
