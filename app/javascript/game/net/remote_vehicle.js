import * as THREE from "three"
import { VehicleView } from "game/render/vehicle_view"
import { vehicleGroups } from "game/physics/groups"

// Another player's car. Rendered from buffered snapshots a fixed delay behind live, so
// jitter and reordering smooth out instead of showing as teleports.
//
// The body is kinematic rather than a ghost, so driving into someone still registers.
// It is driven with setNextKinematic* rather than setTranslation: only the former lets
// Rapier derive a velocity, which is what makes a collision push back at all.
export class RemoteVehicle {
  constructor({ RAPIER, world, scene, spec, colliderIndex, playerId, delay }) {
    this.RAPIER = RAPIER
    this.world = world
    this.spec = spec
    this.playerId = playerId
    this.delay = delay
    this.buffer = []

    const [cw, ch, cl] = spec.chassis.size
    this.body = world.createRigidBody(
      RAPIER.RigidBodyDesc.kinematicPositionBased().setTranslation(0, -50, 0)
    )

    this.colliders = []
    const chassisCollider = world.createCollider(
      RAPIER.ColliderDesc.cuboid(cw / 2, ch / 2, cl / 2)
        .setCollisionGroups(vehicleGroups("remote"))
        .setFriction(0.5),
      this.body
    )
    colliderIndex.set(chassisCollider.handle, {
      kind: "chassis", name: "chassis", part: null, owner: playerId, body: this.body
    })
    this.colliders.push(chassisCollider)

    for (const part of spec.parts) {
      if (part.kind === "jump_jets") continue
      const [pw, ph, pl] = part.size
      const [ox, oy, oz] = part.offset
      const collider = world.createCollider(
        RAPIER.ColliderDesc.cuboid(pw / 2, ph / 2, pl / 2)
          .setCollisionGroups(vehicleGroups("remote"))
          .setTranslation(ox, oy, oz),
        this.body
      )
      colliderIndex.set(collider.handle, {
        kind: part.kind, name: part.name, part, owner: playerId, body: this.body
      })
      this.colliders.push(collider)
    }

    this.view = new VehicleView(scene, spec)
    this.colliderIndex = colliderIndex

    this._position = new THREE.Vector3(0, -50, 0)
    this._rotation = new THREE.Quaternion()
    this._fromPos = new THREE.Vector3()
    this._toPos = new THREE.Vector3()
    this._fromRot = new THREE.Quaternion()
    this._toRot = new THREE.Quaternion()
  }

  push(snapshot, receivedAt) {
    // Snapshots can arrive out of order; a stale one must not rewind the buffer.
    const last = this.buffer[this.buffer.length - 1]
    if (last && snapshot.t <= last.tick) return

    this.buffer.push({
      tick: snapshot.t,
      time: receivedAt,
      p: snapshot.p,
      q: snapshot.q,
      w: snapshot.w,
      f: snapshot.f
    })
    if (this.buffer.length > 40) this.buffer.shift()
  }

  update(now) {
    if (this.buffer.length === 0) return

    const target = now - this.delay
    let from = this.buffer[0]
    let to = this.buffer[this.buffer.length - 1]

    for (let i = 0; i < this.buffer.length - 1; i += 1) {
      if (this.buffer[i].time <= target && this.buffer[i + 1].time >= target) {
        from = this.buffer[i]
        to = this.buffer[i + 1]
        break
      }
    }

    const span = to.time - from.time
    const alpha = span > 0 ? Math.min(Math.max((target - from.time) / span, 0), 1) : 1

    this._fromPos.fromArray(from.p)
    this._toPos.fromArray(to.p)
    this._position.lerpVectors(this._fromPos, this._toPos, alpha)

    this._fromRot.fromArray(from.q)
    this._toRot.fromArray(to.q)
    this._rotation.slerpQuaternions(this._fromRot, this._toRot, alpha)

    this.body.setNextKinematicTranslation(this._position)
    this.body.setNextKinematicRotation(this._rotation)

    this.view.setTransform(this._position, this._rotation)
    this.applyWheels(to.w)

    // Drop samples we have moved past, keeping one before the target to interpolate from.
    while (this.buffer.length > 2 && this.buffer[1].time < target) this.buffer.shift()
  }

  applyWheels(packed) {
    if (!packed || packed.length === 0) return

    this._steer ||= new THREE.Quaternion()
    this._spin ||= new THREE.Quaternion()
    this._axisY ||= new THREE.Vector3(0, 1, 0)
    this._axisX ||= new THREE.Vector3(1, 0, 0)

    this.view.wheels.forEach((entry, i) => {
      const base = i * 3
      const suspension = packed[base] ?? 0
      const rotation = packed[base + 1] ?? 0
      const steering = packed[base + 2] ?? 0
      const anchor = entry.wheel.position

      entry.mesh.position.set(anchor[0], anchor[1] - suspension, anchor[2])
      this._steer.setFromAxisAngle(this._axisY, steering)
      this._spin.setFromAxisAngle(this._axisX, rotation)
      entry.mesh.quaternion.copy(this._steer).multiply(this._spin)
    })
  }

  dispose() {
    for (const collider of this.colliders) this.colliderIndex.delete(collider.handle)
    this.world.removeRigidBody(this.body)
    this.view.dispose()
  }
}
