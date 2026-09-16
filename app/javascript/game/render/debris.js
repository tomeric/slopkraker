import * as THREE from "three"

// The shards a broken piece leaves behind.
//
// These carry no rigid bodies. A house is hundreds of pieces and a good hit takes out five
// at once, each throwing a dozen fragments -- sixty dynamic bodies from one impact, which
// Rapier would feel immediately and which would buy nothing, because nobody drives into
// debris on purpose. They are integrated here instead: gravity, a ground bounce, and some
// tumble, at about a dozen operations per fragment per frame.
//
// The budget is a hard ring. Spawning past the cap retires the oldest rather than refusing
// the new, because the fragment you are looking at is always the one that just appeared.
const GRAVITY = -22.0
const BOUNCE = 0.28
const FRICTION = 0.72
const SPIN = 7.0

export class Debris {
  constructor({ scene, materials, patterns, cap = 260, rules = {}, ground = null }) {
    this.scene = scene
    // (x, z) => the height of the ground there, or null on a world whose ground is flat
    // at zero.
    this.ground = ground
    this.materials = materials
    this.patterns = patterns
    this.cap = cap
    this.rules = rules
    this.live = []
    this.spawned = 0
    // How many have been kicked out of something's way, cumulatively. A test's number.
    this.kicked = 0
    this.pool = []
    this.meshMaterials = new Map()
  }

  materialFor(name) {
    if (this.meshMaterials.has(name)) return this.meshMaterials.get(name)

    const spec = this.materials[name] || {}
    const material = new THREE.MeshStandardMaterial({
      color: spec.colour || "#888888",
      roughness: spec.roughness ?? 0.85,
      metalness: spec.metalness ?? 0.05,
      transparent: (spec.opacity ?? 1) < 1,
      opacity: spec.opacity ?? 1,
      // Debris is seen from every side as it tumbles, and a fragment's cut faces are
      // genuinely open -- without this they vanish at exactly the angles you are watching.
      side: THREE.DoubleSide
    })
    this.meshMaterials.set(name, material)
    return material
  }

  // `matrix` is the broken piece's own transform, so the fragments arrive exactly where it
  // was, at its size and orientation. `away` is the direction the hit came from; fragments
  // are thrown along it so a blast pushes debris outward instead of dropping it.
  spawn(matrix, name, { away = null, force = 1 } = {}) {
    const fragments = this.patterns.for(name)
    if (fragments.length === 0) return 0

    // Cumulative and never reset. `count` is how many are in the air, which decays as they
    // retire, so it cannot answer "did this spawn anything" a moment after the fact.
    this.spawned += fragments.length

    matrix.decompose(POSITION, ROTATION, SCALE)
    const lifetime = 4 + Math.random() * 3

    for (const geometry of fragments) {
      if (this.live.length >= this.cap) this.retire(this.live[0])

      const piece = this.take(geometry, name)
      piece.mesh.geometry = geometry
      piece.mesh.material = this.materialFor(name)
      piece.mesh.scale.copy(SCALE)
      piece.mesh.quaternion.copy(ROTATION)

      // Spread the fragments through the volume the piece occupied, rather than starting
      // them all at its centre where they would visibly emerge from a point.
      OFFSET.set(Math.random() - 0.5, Math.random() - 0.5, Math.random() - 0.5)
        .multiply(SCALE)
        .applyQuaternion(ROTATION)
      piece.mesh.position.copy(POSITION).add(OFFSET)

      piece.velocity.copy(OFFSET).normalize().multiplyScalar((2 + Math.random() * 3) * force)
      if (away) piece.velocity.addScaledVector(away, (3 + Math.random() * 4) * force)
      piece.velocity.y += 2 + Math.random() * 3

      piece.spin.set(rand(SPIN), rand(SPIN), rand(SPIN))
      piece.life = lifetime
      piece.maxLife = lifetime
      piece.age = 0
      piece.kicked = false
      piece.mesh.visible = true

      this.live.push(piece)
    }

    return fragments.length
  }

  take(geometry, name) {
    const piece = this.pool.pop()
    if (piece) return piece

    const mesh = new THREE.Mesh(geometry, this.materialFor(name))
    mesh.castShadow = false
    mesh.receiveShadow = false
    this.scene.add(mesh)
    return { mesh, velocity: new THREE.Vector3(), spin: new THREE.Vector3(), life: 0, maxLife: 1, age: 0, kicked: false }
  }

  // A car has reached these. Everything inside the car's box -- and a margin round it, so
  // the wheels and the wake count -- is kicked away from the car, carried a little with
  // it, and has `kicked_life` left. `frame` is the car's transform and box, worked out once
  // per car per step by the engine. Nothing here is a collision: shards have no bodies.
  sweepVehicle(frame) {
    const grace = this.rules.grace ?? 0.5
    for (const piece of this.live) {
      // Left alone while fresh: a car that breaks a wall is standing in the shards it
      // threw, and they should get to fly before anything kicks them.
      if (piece.kicked || piece.age < grace) continue

      LOCAL.copy(piece.mesh.position).sub(frame.position)
      if (LOCAL.y > frame.top) continue
      LOCAL.applyQuaternion(frame.inverse)
      if (Math.abs(LOCAL.x) > frame.halfX || Math.abs(LOCAL.z) > frame.halfZ) continue

      AWAY.set(piece.mesh.position.x - frame.position.x, 0, piece.mesh.position.z - frame.position.z)
      if (AWAY.lengthSq() < 1e-4) AWAY.copy(frame.forward)
      else AWAY.normalize()

      piece.velocity
        .copy(AWAY).multiplyScalar(this.rules.kick_speed ?? 5)
        .addScaledVector(frame.velocity, this.rules.kick_carry ?? 0.6)
      piece.velocity.y = Math.max(piece.velocity.y, 0) + (this.rules.kick_lift ?? 3)
      piece.spin.set(rand(SPIN), rand(SPIN), rand(SPIN))
      this.finish(piece)
    }
  }

  // A blast has reached these: everything between the radius it had last time and the
  // radius it has now is thrown outward, harder the nearer the centre it sat.
  sweepBlast(at, inner, outer) {
    const grace = this.rules.grace ?? 0.5
    for (const piece of this.live) {
      // The shards this very blast threw are born inside its shell and already flying
      // outward with it; sweeping them too would erase what the blast left behind.
      if (piece.kicked || piece.age < grace) continue

      AWAY.copy(piece.mesh.position).sub(at)
      const distance = AWAY.length()
      if (distance > outer || distance < inner) continue

      const force = 0.4 + 0.6 * (1 - distance / outer)
      if (distance > 1e-4) AWAY.multiplyScalar(1 / distance)
      else AWAY.set(0, 1, 0)

      piece.velocity.copy(AWAY).multiplyScalar((this.rules.blast_speed ?? 12) * force)
      piece.velocity.y += (this.rules.blast_lift ?? 5) * force
      piece.spin.set(rand(SPIN), rand(SPIN), rand(SPIN))
      this.finish(piece)
    }
  }

  // On its way out: whatever life it had, it has `kicked_life` now.
  finish(piece) {
    piece.kicked = true
    piece.life = Math.min(piece.life, this.rules.kicked_life ?? 0.6)
    this.kicked += 1
  }

  update(dt) {
    for (let i = this.live.length - 1; i >= 0; i -= 1) {
      const piece = this.live[i]
      piece.life -= dt
      piece.age += dt
      if (piece.life <= 0) {
        this.retire(piece, i)
        continue
      }

      // The ground under the shard, re-read as it moves: a shard kicked down a slope lands
      // lower than it started. Zero without terrain, as every flat world's ground is.
      const floor = this.ground ? this.ground(piece.mesh.position.x, piece.mesh.position.z) : 0
      const rest = floor + piece.mesh.scale.length() * 0.25
      const remaining = Math.min(piece.life, 1)

      // Its last second, once it is down: sink into the ground rather than blinking out.
      // Deliberately not a scale fade: the fragment's scale is what gives it its shape, and
      // shrinking it uniformly would flatten a shard back into a cube on its way out.
      //
      // Only once it has landed and stopped rising -- a shard still in the air in its last
      // second keeps falling, and one just kicked has to get to fly -- and with the landing
      // clamp below kept out of the way, because clamping it back onto the ground every
      // frame after nudging it under is what quietly kept these from ever sinking at all.
      if (remaining < 1 && piece.mesh.position.y <= rest + 0.01 && piece.velocity.y <= 0) {
        piece.mesh.position.y = rest - (1 - remaining) * piece.mesh.scale.length() * 0.6
        continue
      }

      piece.velocity.y += GRAVITY * dt
      piece.mesh.position.addScaledVector(piece.velocity, dt)

      if (piece.mesh.position.y < rest) {
        piece.mesh.position.y = rest
        piece.velocity.y = Math.abs(piece.velocity.y) * BOUNCE
        piece.velocity.x *= FRICTION
        piece.velocity.z *= FRICTION
        piece.spin.multiplyScalar(FRICTION)
      }

      SPIN_STEP.set(piece.spin.x * dt, piece.spin.y * dt, piece.spin.z * dt)
      TUMBLE.setFromEuler(EULER.setFromVector3(SPIN_STEP))
      piece.mesh.quaternion.multiply(TUMBLE)
    }
  }

  retire(piece, index = this.live.indexOf(piece)) {
    if (index < 0) return

    piece.mesh.visible = false
    this.live.splice(index, 1)
    this.pool.push(piece)
  }

  get spawnedTotal() {
    return this.spawned
  }

  get count() {
    return this.live.length
  }

  // Kicked and still visible: on their way out but not yet gone.
  get kickedLive() {
    let count = 0
    for (const piece of this.live) if (piece.kicked) count += 1
    return count
  }

  dispose() {
    for (const piece of [ ...this.live, ...this.pool ]) piece.mesh.removeFromParent()
    for (const material of this.meshMaterials.values()) material.dispose()
    this.live = []
    this.pool = []
    this.meshMaterials.clear()
  }
}

function rand(scale) {
  return (Math.random() - 0.5) * 2 * scale
}

const POSITION = new THREE.Vector3()
const ROTATION = new THREE.Quaternion()
const SCALE = new THREE.Vector3()
const OFFSET = new THREE.Vector3()
const LOCAL = new THREE.Vector3()
const AWAY = new THREE.Vector3()
const SPIN_STEP = new THREE.Vector3()
const EULER = new THREE.Euler()
const TUMBLE = new THREE.Quaternion()
