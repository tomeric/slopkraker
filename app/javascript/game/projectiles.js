import * as THREE from "three"
import { rocketGroups } from "game/physics/groups"
import { rocketDamage } from "game/damage"
import { createLabel, drawLabel, disposeLabel, wireBox, ARMED_COLOUR } from "game/render/gizmo_label"
import { RocketPlume } from "game/render/rocket_plume"

// Rockets fly two arcs. They lob out of the launcher unpowered, giving up speed to drag
// and arcing under most of a gravity; near the apex the motor lights, and from there they
// accelerate hard while the arc flattens right out. A shot with room to run therefore
// lands far harder than one fired point blank.
//
// They detonate on contact or when their lifetime runs out, and carry whatever damage
// their speed was worth at that moment.
//
// With the debug overlay on, each live rocket wears its own hitbox and damage readout.
export class Projectiles {
  constructor({ RAPIER, world, scene, colliderIndex, onDetonate, onIgnite }) {
    this.RAPIER = RAPIER
    this.world = world
    this.scene = scene
    this.colliderIndex = colliderIndex
    this.onDetonate = onDetonate || (() => {})
    this.onIgnite = onIgnite || (() => {})
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
        .setGravityScale(spec.flight.coast.gravity_scale)
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
      phase: "coast", speed: spec.launch_speed,
      plume: new RocketPlume(this.scene, mesh, spec),
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

      if (rocket.phase === "coast") this.coast(rocket, dt)
      else this.accelerate(rocket, dt)
    }
  }

  // Unpowered: bleeding speed to drag and arcing under most of a gravity.
  //
  // The motor lights just BEFORE the apex -- as the climb decays to ignite_climb, while
  // the rocket is still rising. Waiting for the apex itself does not work: thrust only
  // rescales the heading the rocket already has, so a rocket that has levelled off is
  // flying flat a metre above the ground and the first thing gravity does is tip that
  // heading into the dirt.
  //
  // Bounded at both ends. Never before min_time, because fired down a slope it is already
  // falling on the very first frame, which would light the motor instantly and collapse
  // the two arcs back into one. Never later than max_time, because fired from a
  // fast-moving buggy the inherited velocity can mean the apex never arrives at all.
  coast(rocket, dt) {
    const coast = rocket.spec.flight.coast
    const v = rocket.body.linvel()
    const speed = Math.hypot(v.x, v.y, v.z)

    if (speed > 0.01) {
      const target = Math.max(speed - coast.drag * dt, 0)
      this.rescale(rocket, v, target / speed, target)
    }

    if (rocket.life < coast.min_time) return
    // Scaling by a positive number cannot change how fast it is climbing relative to the
    // threshold in any way that matters here, so the pre-scale v is fine to read.
    if (v.y > coast.ignite_climb && rocket.life < coast.max_time) return

    rocket.phase = "thrust"
    rocket.body.setGravityScale(rocket.spec.flight.thrust.gravity_scale, true)
    this.onIgnite(rocket)
  }

  // Thrust along its own heading, capped at the spec's top speed.
  accelerate(rocket, dt) {
    const thrust = rocket.spec.flight.thrust
    const v = rocket.body.linvel()
    const speed = Math.hypot(v.x, v.y, v.z)
    if (speed < 0.01) return

    const target = Math.min(speed + thrust.acceleration * dt, thrust.max_speed)
    this.rescale(rocket, v, target / speed, target)
  }

  // Both phases only ever change how fast the rocket is going, never which way it points,
  // so they share the same rescale -- and damage tracks the new speed either way.
  rescale(rocket, v, scale, speed) {
    rocket.body.setLinvel({ x: v.x * scale, y: v.y * scale, z: v.z * scale }, true)
    rocket.speed = speed
    rocket.damage = rocketDamage(rocket.spec, speed)
  }

  markDead(rocket) {
    rocket.dead = true
  }

  detonate(rocket) {
    const t = rocket.body.translation()
    const at = new THREE.Vector3(t.x, t.y, t.z)

    this.colliderIndex.delete(rocket.collider.handle)
    this.world.removeRigidBody(rocket.body)
    rocket.thrustVoice?.stop()
    rocket.plume.dispose()
    rocket.mesh.removeFromParent()
    rocket.box.removeFromParent()
    rocket.label.sprite.removeFromParent()
    disposeLabel(rocket.label)

    // The blast is worth what the rocket was worth when it landed.
    this.onDetonate(at, rocket.spec, rocket.damage)
  }

  sync(dt) {
    for (const rocket of this.live) {
      const t = rocket.body.translation()
      rocket.mesh.position.set(t.x, t.y, t.z)

      // Point the rocket along its own velocity so it noses over through the arc.
      const v = rocket.body.linvel()
      if (v.x || v.y || v.z) rocket.mesh.lookAt(t.x + v.x, t.y + v.y, t.z + v.z)

      rocket.plume.update(dt, rocket.mesh.position, rocket.phase === "thrust")

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
      rocket.thrustVoice?.stop()
      rocket.plume.dispose()
      rocket.mesh.removeFromParent()
      rocket.box.removeFromParent()
      rocket.label.sprite.removeFromParent()
      disposeLabel(rocket.label)
    }
    this.live = []
    this.geometry.dispose()
  }
}
