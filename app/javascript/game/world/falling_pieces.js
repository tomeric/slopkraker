import * as THREE from "three"
import { FALLING_GROUPS } from "game/physics/groups"

// The stage between a building being condemned and its pieces being gone.
//
// A collapse used to replace a house with a cloud of shards between one frame and the
// next, which reads as the building being deleted rather than as it falling down. So a
// condemned piece gets one last life here: a real dynamic body carrying the panel's own
// size, orientation and mass, which falls, tumbles, and throws the shards it used to throw
// at the moment it lands instead of the moment it was condemned.
//
// These are the opposite of a standing piece in every way that matters. A standing piece
// is a fixed collider that is never freed, which is what makes breaking it O(1) and puts
// it out of reach of the wasm lifetime footgun entirely. These are genuine rigid bodies,
// so that footgun is live, and the two rules it demands are load-bearing here:
//
//   - A body is never created or freed inside a drain callback. Rapier borrows the world
//     mutably for the duration of one, and Rust's aliasing check trips. A landing is
//     noticed during the drain and merely MARKED; the freeing happens in update().
//   - A body's transform is read BEFORE it is freed. The shards spawn where the piece
//     actually came to rest, and reading a freed body reaches into released memory and
//     poisons the whole Rapier instance -- not just this piece.
export class FallingPieces {
  constructor({ RAPIER, world, scene, colliderIndex, materials, debris, rules = {}, looks = null }) {
    this.RAPIER = RAPIER
    this.world = world
    this.scene = scene
    this.colliderIndex = colliderIndex
    this.materials = materials
    this.debris = debris
    this.looks = looks

    this.max = rules.max ?? 140
    this.perBuilding = rules.per_building ?? this.max
    this.arm = rules.arm ?? 0.12
    this.maxLife = rules.life ?? 6.0
    this.drift = rules.drift ?? 1.6
    this.spinRate = rules.spin ?? 2.2
    this.linearDamping = rules.linear_damping ?? 0.05
    this.angularDamping = rules.angular_damping ?? 0.4
    this.densityScale = rules.density_scale ?? 1.0
    this.shardsPerSlab = rules.shards_per_slab ?? 3

    this.geometry = new THREE.BoxGeometry(1, 1, 1)
    this.live = []
    this.pool = []
    this.cells = 0
  }

  // How many slabs THIS collapse may put in the air. The caller thins its condemned set
  // down to this before it starts breaking, rather than handing over a thousand and
  // letting the pool chew through them -- a piece that is dropped to make room for the
  // next one never got to fall, which is the entire point.
  //
  // TWO limits, and the difference between them is what a street costs and one house did
  // not. `perBuilding` is how coarsely one house is allowed to come apart, which is a
  // question about that house. What is FREE is a question about the world, and it is the
  // one this used to skip: it returned the ceiling whole, so a second collapse read six
  // hundred as available while six hundred were already up there, dropped its full
  // complement on top, and left the pool to make room out of a building that was still
  // falling.
  //
  // With one building in the world the two were the same number, which is exactly why
  // this survived being read and re-read.
  budgetForCollapse() {
    return Math.max(Math.min(this.perBuilding, this.max - this.live.length), 0)
  }

  // Takes over drawing the piece: the caller hides its instance and throws no shards,
  // because both of those are this object's job now. Returns false if it could not, in
  // which case the piece breaks the way it always did.
  //
  // Safe to call from a net message, which is where collapses come from -- but never from
  // inside a drain, because this creates bodies. Nothing does; the comment is here because
  // a future caller might.
  drop(matrix, name, shape = SINGLE_CELL) {
    if (!matrix || !this.RAPIER) return false

    // Full means NO, never "make room". A slab already in the air belongs to a building
    // that is still coming down, and taking it back is the one thing this file exists to
    // prevent: it shatters in the sky, and its owner counts it as landed and reveals the
    // wreckage it was carrying under a house that has not finished falling.
    //
    // The caller has already asked budgetForCollapse() and thinned itself to fit, so this
    // is a backstop rather than the mechanism. Returning false is not a failure -- the
    // cell simply breaks where it stands, which is what everything did before slabs
    // existed.
    if (this.live.length >= this.max) return false

    matrix.decompose(POSITION, ROTATION, SCALE)
    const spec = this.materials[name] || {}

    const body = this.world.createRigidBody(
      this.RAPIER.RigidBodyDesc.dynamic()
        .setTranslation(POSITION.x, POSITION.y, POSITION.z)
        .setRotation({ x: ROTATION.x, y: ROTATION.y, z: ROTATION.z, w: ROTATION.w })
        .setLinvel(rand(this.drift), 0, rand(this.drift))
        .setAngvel({ x: rand(this.spinRate), y: rand(this.spinRate), z: rand(this.spinRate) })
        .setLinearDamping(this.linearDamping)
        .setAngularDamping(this.angularDamping)
    )

    const collider = this.world.createCollider(
      this.RAPIER.ColliderDesc.cuboid(SCALE.x / 2, SCALE.y / 2, SCALE.z / 2)
        // Its real mass, from the material's own density and the cell's own volume. A
        // brick panel weighs what a brick panel weighs, which is what makes one landing on
        // the car feel like masonry rather than cardboard.
        .setDensity((spec.density ?? 800) * this.densityScale)
        .setCollisionGroups(FALLING_GROUPS)
        .setFriction(spec.friction ?? 0.8)
        .setRestitution(spec.restitution ?? 0.05)
        // COLLISION and not CONTACT_FORCE, unlike a standing piece. What matters here is
        // that it touched something at all, not how hard -- a slab settling gently onto
        // rubble has still landed.
        .setActiveEvents(this.RAPIER.ActiveEvents.COLLISION_EVENTS),
      body
    )

    const entry = this.take(name)
    entry.body = body
    entry.collider = collider
    entry.age = 0
    entry.touched = false
    // The grid this slab covered, kept so its landing can be broken back down into cells.
    entry.rows = shape.rows
    entry.cols = shape.cols
    entry.cells = shape.cells
    // Who to tell when this lands. A building's wreckage arrives by falling on the ground,
    // so the heaps are revealed by the slabs arriving rather than by the collapse being
    // decided -- otherwise the wall sections fall through rubble that is already lying
    // where they are about to land.
    entry.owner = shape.owner ?? null
    // And which of its bays. A terrace reveals a dwelling's wreckage as that dwelling's own
    // slabs land, so the bay has to travel with the slab and come back with the landing.
    entry.bay = shape.bay ?? 0
    this.cells += shape.cells
    entry.mesh.scale.copy(SCALE)
    entry.mesh.position.copy(POSITION)
    entry.mesh.quaternion.copy(ROTATION)
    // A slab keeps the look and the colour it fell with. The material is this entry's own
    // -- a slab's tint is per mesh -- and is remade only when the entry changes material,
    // because the textures under it are shared and a material is cheap.
    if (entry.name !== name || !entry.mesh.material.userData.slab) {
      entry.mesh.material.dispose()
      entry.mesh.material = this.slabMaterial(name)
    }
    entry.mesh.material.color.copy(shape.tint ?? WHITE)
    entry.name = name
    entry.mesh.visible = true

    this.colliderIndex.set(collider.handle, { kind: "falling", falling: entry })
    this.live.push(entry)
    return true
  }

  // A slab's own material, never a shared one: its colour is the building's palette and
  // two houses on the same street are not the same colour. The textures under it are
  // shared, so this costs a uniform block and nothing else.
  slabMaterial(name) {
    const material = this.looks ? this.looks.slabMaterial(name) : this.debris.materialFor(name).clone()
    material.userData.slab = true
    return material
  }

  take(name) {
    const entry = this.pool.pop()
    if (entry) return entry

    const mesh = new THREE.Mesh(this.geometry, this.slabMaterial(name))
    mesh.castShadow = true
    mesh.receiveShadow = false
    this.scene.add(mesh)
    return {
      mesh, body: null, collider: null, name, age: 0, touched: false,
      rows: 1, cols: 1, cells: 1, owner: null, bay: 0
    }
  }

  // Called from inside the collision drain, so it may only set a flag.
  //
  // The flag is REMEMBERED rather than discarded when the piece is too young to act on it,
  // and that is the whole of what this has to get right. Rapier reports a contact STARTING,
  // not a contact continuing -- so a piece that was already resting on something when it
  // was condemned gets exactly one of these, on its first frame, and no second one is ever
  // coming, because it never stops touching what it is sitting on. Discarding that one
  // event left a ground floor's worth of panels standing where they were until `life` ran
  // out and then vanishing together. Measured: twenty-two of a hundred and thirty-two.
  markTouched(entry) {
    if (!entry) return
    entry.touched = true
  }

  update(dt) {
    for (let i = this.live.length - 1; i >= 0; i -= 1) {
      const entry = this.live[i]
      entry.age += dt
      // Armed first, always: a piece gets its moment in the air before anything it is
      // touching is allowed to end it. Without that, a storey condemned on top of one still
      // standing bursts against it in the frame it was condemned, which is the very
      // behaviour this file exists to replace.
      if (entry.age < this.arm) continue
      if (entry.touched || entry.age >= this.maxLife) this.shatter(entry, i)
    }
  }

  // Read the transform BEFORE the body goes. The shards have to appear where the piece
  // came to rest rather than where it was condemned, and a body's translation is the one
  // thing that cannot be asked for afterwards.
  //
  // Shards are thrown ONE CELL AT A TIME across the slab, never once for the slab itself.
  // Debris takes its fragment size from the matrix it is handed, so a single burst at slab
  // scale would shower a four metre wall section in four metre splinters. Spreading a few
  // cell-sized bursts through the volume keeps rubble the size rubble has always been,
  // however large the thing that produced it got.
  shatter(entry, index = this.live.indexOf(entry)) {
    if (index < 0) return

    const at = entry.body.translation()
    const rot = entry.body.rotation()
    LANDED_AT.set(at.x, at.y, at.z)
    LANDED_ROT.set(rot.x, rot.y, rot.z, rot.w)

    const size = entry.mesh.scale
    CELL_SCALE.set(size.x / entry.cols, size.y / entry.rows, size.z)

    // Strided rather than the first few, so a long slab does not throw all its rubble out
    // of one end.
    const total = entry.rows * entry.cols
    const bursts = Math.min(entry.cells, this.shardsPerSlab)
    const stride = Math.max(1, Math.floor(total / bursts))

    for (let cell = 0; cell < total; cell += stride) {
      const row = Math.floor(cell / entry.cols)
      const col = cell % entry.cols
      // The slab's local axes are the surface's -- x along its columns, y along its rows --
      // which is what chunkMatrix promises and what makes this arithmetic legal.
      OFFSET.set((col + 0.5) / entry.cols - 0.5, (row + 0.5) / entry.rows - 0.5, 0)
        .multiply(size)
        .applyQuaternion(LANDED_ROT)
      MATRIX.compose(BURST_AT.copy(LANDED_AT).add(OFFSET), LANDED_ROT, CELL_SCALE)
      this.debris.spawn(MATRIX, entry.name)
    }

    this.cells -= entry.cells
    entry.owner?.slabLanded(entry.bay)
    entry.owner = null
    this.colliderIndex.delete(entry.collider.handle)
    this.world.removeRigidBody(entry.body)
    entry.body = null
    entry.collider = null
    entry.mesh.visible = false

    this.live.splice(index, 1)
    this.pool.push(entry)
  }

  sync() {
    for (const entry of this.live) {
      const at = entry.body.translation()
      const rot = entry.body.rotation()
      entry.mesh.position.set(at.x, at.y, at.z)
      entry.mesh.quaternion.set(rot.x, rot.y, rot.z, rot.w)
    }
  }

  get count() {
    return this.live.length
  }

  // How many CELLS are in the air, as against how many bodies are carrying them. The two
  // together are the whole measure of this file: the first says how much of the house left
  // the ground, the second how coarsely it did it.
  get cellCount() {
    return this.cells
  }

  dispose() {
    for (const entry of this.live) {
      this.colliderIndex.delete(entry.collider.handle)
      this.world.removeRigidBody(entry.body)
      entry.mesh.removeFromParent()
      // Per entry, so nobody else is holding it. The textures on it belong to Looks and
      // are freed there.
      entry.mesh.material.dispose()
      entry.owner = null
    }
    for (const entry of this.pool) {
      entry.mesh.removeFromParent()
      entry.mesh.material.dispose()
    }
    this.live = []
    this.pool = []
    this.cells = 0
    this.geometry.dispose()
  }
}

function rand(scale) {
  return (Math.random() - 0.5) * 2 * scale
}

const SINGLE_CELL = { rows: 1, cols: 1, cells: 1 }
const WHITE = new THREE.Color(1, 1, 1)

const POSITION = new THREE.Vector3()
const LANDED_AT = new THREE.Vector3()
const LANDED_ROT = new THREE.Quaternion()
const CELL_SCALE = new THREE.Vector3()
const OFFSET = new THREE.Vector3()
const BURST_AT = new THREE.Vector3()
const ROTATION = new THREE.Quaternion()
const SCALE = new THREE.Vector3()
const MATRIX = new THREE.Matrix4()
