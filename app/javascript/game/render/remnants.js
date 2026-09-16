import * as THREE from "three"

// The couple of pieces of rubbish a cleared heap leaves lying where it was.
//
// A heap is an instanced piece and vanishes in the frame it breaks, which is right for a
// wall panel and wrong for a pile of garbage: a heap you drove through should leave a few
// chunks of itself behind that settle onto the ground, lie there a moment, and then fade
// away into it. These are those chunks.
//
// Plain meshes with a material EACH, not instances, because fading is a per-piece opacity
// and an InstancedMesh has one material. That is only affordable because there are never
// many -- three per heap, gone in four seconds -- and it is why the pool has a hard cap
// that retires the oldest rather than refusing the new.
//
// Purely local. Nothing about a remnant crosses the wire: the heap it came from is what
// is shared, and by the time one of these exists that heap is already gone everywhere.
export class Remnants {
  constructor({ scene, materials, rules = {}, sweep = {}, cap = 96, ground = null }) {
    this.scene = scene
    // (x, z) => the height of the ground there, or null on a world whose ground is flat
    // at zero.
    this.ground = ground
    this.materials = materials
    this.settleTime = rules.settle ?? 0.35
    this.lingerTime = rules.linger ?? 2.0
    this.fadeTime = rules.fade ?? 1.5
    // How a car or a blast kicks one: the same numbers the shards use.
    this.sweep = sweep
    this.cap = cap
    this.live = []
    this.pool = []
    this.kicked = 0
    this.templates = new Map()
  }

  templateFor(name) {
    if (this.templates.has(name)) return this.templates.get(name)

    const spec = this.materials[name] || {}
    const material = new THREE.MeshStandardMaterial({
      color: spec.colour || "#888888",
      roughness: spec.roughness ?? 0.85,
      metalness: spec.metalness ?? 0.05,
      opacity: spec.opacity ?? 1
    })
    this.templates.set(name, material)
    return material
  }

  // `matrix` is the chunk's transform as it lay in the heap. The geometry is the pool's
  // own, shared, so a remnant is the very chunk that was drawn there a frame ago.
  add(geometry, name, matrix) {
    if (this.live.length >= this.cap) this.retire(this.live[0], 0)

    const template = this.templateFor(name)
    const entry = this.take()
    const mesh = entry.mesh
    matrix.decompose(mesh.position, mesh.quaternion, mesh.scale)
    mesh.geometry = geometry
    mesh.material.copy(template)
    mesh.material.transparent = true
    mesh.material.opacity = template.opacity
    mesh.visible = true

    entry.age = 0
    entry.kicked = false
    entry.kickedAge = 0
    entry.from = mesh.position.y
    entry.opacity = template.opacity
    // How far above the ground it comes to rest: local y is the chunk's thickness and
    // stays roughly up, so a little over a third of that. The ground itself is sampled
    // where the chunk is, every frame, because a kicked one moves.
    entry.lift = Math.max(mesh.scale.y, 0.05) * 0.35
    entry.depth = mesh.scale.length() * 0.6
    this.live.push(entry)
    return entry
  }

  take() {
    const entry = this.pool.pop()
    if (entry) return entry

    const mesh = new THREE.Mesh(PLACEHOLDER, new THREE.MeshStandardMaterial({ transparent: true }))
    mesh.castShadow = true
    mesh.receiveShadow = false
    this.scene.add(mesh)
    return {
      mesh, age: 0, from: 0, lift: 0, depth: 0, opacity: 1,
      kicked: false, kickedAge: 0, velocity: new THREE.Vector3(), spin: new THREE.Vector3()
    }
  }

  // A car has reached these: everything inside its box and margin is kicked away from it.
  // Same shape as Debris#sweepVehicle, for the same reason -- a remnant has no body either.
  sweepVehicle(frame) {
    const grace = this.sweep.grace ?? 0.5
    for (const entry of this.live) {
      // Left alone while fresh, or the truck that cleared the heap would sweep the very
      // chunks that are meant to lie there a moment as it drove on over them.
      if (entry.kicked || entry.age < grace) continue

      LOCAL.copy(entry.mesh.position).sub(frame.position)
      if (LOCAL.y > frame.top) continue
      LOCAL.applyQuaternion(frame.inverse)
      if (Math.abs(LOCAL.x) > frame.halfX || Math.abs(LOCAL.z) > frame.halfZ) continue

      AWAY.set(entry.mesh.position.x - frame.position.x, 0, entry.mesh.position.z - frame.position.z)
      if (AWAY.lengthSq() < 1e-4) AWAY.copy(frame.forward)
      else AWAY.normalize()

      entry.velocity
        .copy(AWAY).multiplyScalar(this.sweep.kick_speed ?? 5)
        .addScaledVector(frame.velocity, this.sweep.kick_carry ?? 0.6)
      entry.velocity.y = Math.max(entry.velocity.y, 0) + (this.sweep.kick_lift ?? 3)
      this.kick(entry)
    }
  }

  // A blast has reached these: thrown outward, harder the nearer the centre.
  sweepBlast(at, inner, outer) {
    const grace = this.sweep.grace ?? 0.5
    for (const entry of this.live) {
      if (entry.kicked || entry.age < grace) continue

      AWAY.copy(entry.mesh.position).sub(at)
      const distance = AWAY.length()
      if (distance > outer || distance < inner) continue

      const force = 0.4 + 0.6 * (1 - distance / outer)
      if (distance > 1e-4) AWAY.multiplyScalar(1 / distance)
      else AWAY.set(0, 1, 0)

      entry.velocity.copy(AWAY).multiplyScalar((this.sweep.blast_speed ?? 12) * force)
      entry.velocity.y += (this.sweep.blast_lift ?? 5) * force
      this.kick(entry)
    }
  }

  kick(entry) {
    entry.kicked = true
    entry.kickedAge = 0
    entry.spin.set(rand(SPIN), rand(SPIN), rand(SPIN))
    this.kicked += 1
  }

  // Where this chunk comes to rest: the ground under it, plus its own lift.
  restOf(entry) {
    const at = entry.mesh.position
    return (this.ground ? this.ground(at.x, at.z) : 0) + entry.lift
  }

  // Settle, linger, then fade while sinking. The sink is deliberately not a scale fade:
  // the chunk's scale is what gives it its shape, and shrinking it would turn a plank back
  // into a cube on its way out.
  update(dt) {
    for (let i = this.live.length - 1; i >= 0; i -= 1) {
      const entry = this.live[i]
      const mesh = entry.mesh
      entry.age += dt
      const rest = this.restOf(entry)

      // Kicked: it flies, tumbles and fades out over `kicked_life`, whatever stage of
      // settling or lingering it was at.
      if (entry.kicked) {
        entry.kickedAge += dt
        const life = this.sweep.kicked_life ?? 0.6
        if (entry.kickedAge >= life) {
          this.retire(entry, i)
          continue
        }

        entry.velocity.y += GRAVITY * dt
        mesh.position.addScaledVector(entry.velocity, dt)
        if (mesh.position.y < rest) {
          mesh.position.y = rest
          entry.velocity.y = 0
        }
        SPIN_STEP.set(entry.spin.x * dt, entry.spin.y * dt, entry.spin.z * dt)
        TUMBLE.setFromEuler(EULER.setFromVector3(SPIN_STEP))
        mesh.quaternion.multiply(TUMBLE)
        mesh.material.opacity = entry.opacity * (1 - entry.kickedAge / life)
        continue
      }

      if (entry.age < this.settleTime) {
        const t = ease(entry.age / this.settleTime)
        mesh.position.y = entry.from + (rest - entry.from) * t
        continue
      }

      const fading = entry.age - this.settleTime - this.lingerTime
      if (fading < 0) {
        mesh.position.y = rest
        continue
      }
      if (fading >= this.fadeTime) {
        this.retire(entry, i)
        continue
      }

      const f = fading / this.fadeTime
      mesh.material.opacity = entry.opacity * (1 - f)
      mesh.position.y = rest - entry.depth * f
    }
  }

  retire(entry, index = this.live.indexOf(entry)) {
    if (index < 0) return

    entry.mesh.visible = false
    this.live.splice(index, 1)
    this.pool.push(entry)
  }

  get count() {
    return this.live.length
  }

  get kickedLive() {
    let count = 0
    for (const entry of this.live) if (entry.kicked) count += 1
    return count
  }

  dispose() {
    for (const entry of [ ...this.live, ...this.pool ]) {
      entry.mesh.removeFromParent()
      entry.mesh.material.dispose()
    }
    for (const material of this.templates.values()) material.dispose()
    this.live = []
    this.pool = []
    this.templates.clear()
  }
}

function ease(t) {
  return 1 - (1 - t) * (1 - t)
}

function rand(scale) {
  return (Math.random() - 0.5) * 2 * scale
}

// Same as the shards': a kicked remnant is a shard for the rest of its short life.
const GRAVITY = -22.0
const SPIN = 7.0

const PLACEHOLDER = new THREE.BoxGeometry(1, 1, 1)
const LOCAL = new THREE.Vector3()
const AWAY = new THREE.Vector3()
const SPIN_STEP = new THREE.Vector3()
const EULER = new THREE.Euler()
const TUMBLE = new THREE.Quaternion()
