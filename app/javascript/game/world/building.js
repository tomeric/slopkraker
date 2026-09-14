import * as THREE from "three"
import { PROP_GROUPS } from "game/physics/groups"
import { eachBuildingCell, materialAt, chunkMatrix } from "game/world/surface"
import { tileSurface } from "game/world/chunking"
import { rubbleMatrix, shapeFor, pileOrder, SHAPES } from "game/world/rubble"
import { absorb } from "game/damage"

// One building, expanded from its surfaces into pieces that can be hit.
//
// A piece is a FIXED COLLIDER WITH NO RIGID BODY. A wall panel never moves, so giving it a
// dynamic body would mean a transform read back from wasm and an interpolation step every
// frame, for something that is standing still. Hundreds of those per building is the
// difference between a city that runs and one that does not.
//
// It also decides how breaking works. Because nothing is ever freed, a break is
// collider.setEnabled(false) plus a zero-scale instance: O(1), allocation-free, and
// reversible. Nothing can be touched after being freed because nothing is freed -- the
// wasm lifetime footgun that CLAUDE.md documents simply cannot fire here. And when the
// server has the last word on whether a break really happened, putting a piece back is the
// same two calls in reverse.
//
// Piece state is held in flat typed arrays rather than objects. There is one entry per
// piece index, `void` cells included, so a piece index is a direct offset -- no map, no
// search, and the arithmetic stays the same on both sides of the wire.
const INTACT = 0
const BROKEN = 1
const ABSENT = 2
// A heap of rubble the building has not yet fallen down to produce. Reserved index space
// like ABSENT, but unlike ABSENT it is waiting rather than permanently empty.
//
// DORMANT -> INTACT -> BROKEN is still strictly monotone: a piece enters one state earlier
// than it used to and never moves backwards, so every server message stays idempotent.
const DORMANT = 3

export class Building {
  constructor({ RAPIER, world, spec, materials, meshes, colliderIndex, contactThreshold, spread = 0, debris = null, falling = null, grid = null, rules = {}, chunk = null, rubbleRules = null, onDamage = null }) {
    this.spec = spec
    this.materials = materials
    this.meshes = meshes
    this.world = world
    this.contactThreshold = contactThreshold
    this.spread = spread
    this.debris = debris
    this.falling = falling
    this.grid = grid
    this.rules = rules
    this.chunkSize = chunk
    this.rubbleRules = rubbleRules || {}
    // How much wreckage is owed, and how many falling slabs are still to deliver it.
    this.pendingRubble = 0
    this.expectedSlabs = 0
    this.landedSlabs = 0
    this.onDamage = onDamage
    this.origin = new THREE.Vector3().fromArray(spec.o)
    // Bound once: the tiling asks this per cell, and it is asked a few thousand times.
    this.standingAt = (index) => this.standing(index)
    this.id = spec.id
    this.name = spec.name

    const count = spec.piece_count
    this.state = new Uint8Array(count)
    this.health = new Float32Array(count)
    this.maxHealth = new Float32Array(count)
    this.slot = new Int32Array(count).fill(-1)
    this.material = new Array(count)
    this.pool = new Array(count)
    this.colliders = new Array(count)
    this.matrices = new Array(count)
    // Which surface each piece belongs to, so a hit can find the cells around it. -1 for
    // an index nothing was built at.
    this.surfaceOf = new Int32Array(count).fill(-1)
    // Which cells break together. -1 for a cell that is its own piece -- a roof tile, a
    // floor slab, anything the generator left on the plain grid.
    this.blockOf = new Int32Array(count).fill(-1)
    this.blockCells = []

    this.build(RAPIER, colliderIndex)
  }

  get pieceCount() {
    return this.state.length
  }

  // Tallied first, because an InstancedMesh cannot grow once allocated.
  static countMaterials(spec, into = new Map(), shapes = SHAPES) {
    for (const surface of spec.surfaces) {
      for (let row = 0; row < surface.rows; row += 1) {
        for (let col = 0; col < surface.cols; col += 1) {
          const name = materialAt(surface, row, col)
          if (name === "void") continue

          const pool = Building.poolName(surface, row, col, name, shapes)
          into.set(pool, (into.get(pool) || 0) + 1)
        }
      }
    }
    return into
  }

  // Which instanced pool a cell is drawn from. Everything but rubble is drawn from its
  // material's own pool; a heap picks one of several lumps, so that a cleared site is not
  // the same shape repeated forty times. The suffix chooses a SHAPE and never a material.
  static poolName(surface, row, col, name, shapes = SHAPES) {
    return surface.kind === "rubble" ? `${name}#${shapeFor(surface, row, col, shapes)}` : name
  }

  build(RAPIER, colliderIndex) {
    const surfaceIndex = new Map(this.spec.surfaces.map((surface, i) => [ surface, i ]))
    // Block ids are local to their surface, so they are rebased onto a building-wide id
    // as each surface is walked.
    const blockBase = new Map()

    eachBuildingCell(this.spec, (index, name, matrix, surface, row, col) => {
      this.material[index] = name
      this.surfaceOf[index] = surfaceIndex.get(surface)
      this.assignBlock(index, surface, blockBase)

      // A doorway. It holds an index so the arithmetic stays uniform, and nothing else.
      if (name === "void") {
        this.state[index] = ABSENT
        return
      }

      // A heap sits where its cell is, shrunk, spun and nudged off centre so a cleared
      // site does not read as the grid it is laid out on. Deterministic in the surface's
      // seed, which is what makes two players agree about where it is.
      const rubble = surface.kind === "rubble"
      if (rubble) rubbleMatrix(surface, row, col, matrix, this.origin, this.rubbleRules)

      this.matrices[index] = matrix.clone()
      // Keyed by material, not per surface: a glass window in a brick wall has to break
      // like glass, not like the wall it is set into.
      const health = surface.hp[name] ?? 0
      this.health[index] = health
      this.maxHealth[index] = health
      // The pool a piece is DRAWN from, which is its material for everything except a heap
      // of rubble. Kept per piece, because hiding and tinting address the pool while damage
      // and breaking address the material.
      this.pool[index] = Building.poolName(surface, row, col, name, this.rubbleRules.shapes)
      this.slot[index] = this.meshes.add(this.pool[index], matrix)
      this.colliders[index] = this.createCollider(RAPIER, matrix, surface, name, index, colliderIndex)

      // Built now and revealed later. The collider array and the instance pool are both
      // allocated at boot and cannot grow, so the only way a heap can appear when a house
      // comes down is for it to have been here, switched off, all along.
      if (rubble) {
        this.state[index] = DORMANT
        this.meshes.setVisible(this.pool[index], this.slot[index], false)
        this.colliders[index]?.setEnabled(false)
        return
      }

      // Into the blast grid, so an explosion can find this piece. Static: a wall panel
      // never moves, so it is placed once and never revisited -- which is the property
      // that lets the grid hold a city's worth of them.
      if (this.grid) {
        matrix.decompose(POSITION, ROTATION, SCALE)
        this.grid.insert(this.target(index), POSITION.x, POSITION.y, POSITION.z)
      }
    })
  }

  createCollider(RAPIER, matrix, surface, name, index, colliderIndex) {
    matrix.decompose(POSITION, ROTATION, SCALE)
    const material = this.materials[name] || {}

    const collider = this.world.createCollider(
      RAPIER.ColliderDesc.cuboid(SCALE.x / 2, SCALE.y / 2, SCALE.z / 2)
        .setTranslation(POSITION.x, POSITION.y, POSITION.z)
        .setRotation({ x: ROTATION.x, y: ROTATION.y, z: ROTATION.z, w: ROTATION.w })
        // LAYER.PROP, so the bull bar and the slam plate reach a wall exactly as they
        // reach a crate. groups.js already promised this: "walls become destructible props
        // in time, at which point the PROP bit catches them like anything else."
        .setCollisionGroups(PROP_GROUPS)
        .setFriction(material.friction ?? 0.8)
        .setRestitution(material.restitution ?? 0.05)
        .setActiveEvents(RAPIER.ActiveEvents.CONTACT_FORCE_EVENTS)
        .setContactForceEventThreshold(this.contactThreshold)
    )

    colliderIndex.set(collider.handle, {
      kind: "piece", name: `${this.name}:${index}`, destructible: true,
      building: this, piece: index
    })
    return collider
  }

  assignBlock(index, surface, blockBase) {
    if (!surface.blocks) return

    const local = surface.blocks[index - surface.off]
    if (local === undefined || local === null) return

    if (!blockBase.has(surface)) blockBase.set(surface, this.blockCells.length)
    const id = blockBase.get(surface) + local

    while (this.blockCells.length <= id) this.blockCells.push([])
    this.blockCells[id].push(index)
    this.blockOf[index] = id
  }

  // Every cell that shares this one's fate, itself included.
  block(index) {
    const id = this.blockOf[index]
    return id < 0 ? SINGLE_CELL(index) : this.blockCells[id]
  }

  // The handle a blast holds onto. Built once per piece and kept, so a blast query hands
  // back something that already knows which building and which cell it is.
  target(index) {
    this.targets ||= new Array(this.state.length)
    this.targets[index] ||= { building: this, piece: index }
    return this.targets[index]
  }

  materialSpec(index) {
    return this.materials[this.material[index]]
  }

  standing(index) {
    return this.state[index] === INTACT
  }

  // The cells sharing an edge with this one, within its own surface. Bounded by the
  // surface rather than by the index, so a hit at the end of a row does not wrap onto the
  // start of the next one, and a hit on a wall never spreads onto the roof.
  neighbours(index) {
    const surface = this.spec.surfaces[this.surfaceOf[index]]
    if (!surface) return []

    const local = index - surface.off
    const row = Math.floor(local / surface.cols)
    const col = local % surface.cols
    const out = []

    if (col > 0) out.push(index - 1)
    if (col < surface.cols - 1) out.push(index + 1)
    if (row > 0) out.push(index - surface.cols)
    if (row < surface.rows - 1) out.push(index + surface.cols)
    return out
  }

  // `raw` is damage before the target has had any say in it. Each cell absorbs it with
  // ITS OWN material, which is the only way the spread can be right: a steel lintel set
  // into a brick wall has to resist what reaches it as steel. Absorbing once at the centre
  // and passing the result outward meant the lintel took brick's arithmetic at 70% and
  // fell out of a wall it should have outlasted.
  //
  // A hit carries into the cells around it. Without that, the most a single impact can do
  // is remove the one 1.5m panel it touched -- which looks like a car chipping a wall
  // rather than going through it, however lethal the hit was. Spreading turns one good
  // impact into a hole with a shape.
  //
  // The spread does not spread again: passing 0 on the recursive call is what stops one
  // hit walking across the whole building.
  damage(index, raw, kind = "impact", spread = this.spread, away = null) {
    if (spread > 0) {
      for (const near of this.neighbours(index)) this.damage(near, raw * spread, kind, 0, away)
    }

    // The whole block takes the hit, not just the cell that was touched. That is what
    // makes a hole follow a shape instead of a square -- and since every cell of a block
    // is the same material with the same health, they come away together.
    let broke = false
    for (const cell of this.block(index)) broke = this.damageCell(cell, raw, kind, away) || broke
    return broke
  }

  damageCell(index, raw, kind, away) {
    if (!this.standing(index)) return false

    const amount = absorb(raw, this.materialSpec(index), kind, this.rules)
    if (amount <= 0) return false

    // Reported RAW, before this cell's material has taken its cut. The server runs the
    // same absorb from the same table; sending `amount` would apply the material twice.
    // Reported per cell rather than per hit, because spread and block tiling have already
    // happened here and the server has no business knowing about either.
    this.onDamage?.(this.id, index, raw, kind)

    this.health[index] -= amount
    if (this.health[index] > 0) {
      this.meshes.tint(this.pool[index], this.slot[index], this.health[index] / this.maxHealth[index])
      return false
    }

    this.breakCell(index, away)
    return true
  }

  // Breaks the whole block, so the hooks and the server both address a piece the way a
  // hit does.
  break(index, away = null) {
    let broke = false
    for (const cell of this.block(index)) broke = this.breakCell(cell, away) || broke
    return broke
  }

  // `silent` is the difference between something breaking and something having been
  // broken. A hit throws shards; restoring a ruin someone else left must not, or every
  // page load re-stages a demolition that happened in a session long gone.
  //
  // `carried` is the difference between a piece being knocked out and a piece being
  // condemned. Either way it stops being part of the building in this very frame -- state,
  // blast grid and collider all go at once, because structurally it IS gone -- but a
  // condemned cell has handed its appearance to the slab falling on its behalf, so it must
  // not also throw shards where it stood. The slab throws them when it lands.
  breakCell(index, away = null, silent = false, carried = false) {
    // DORMANT counts as breakable, not as already broken, and that distinction is load
    // bearing. A heap the server says was cleared in some earlier session has to be able
    // to go straight to BROKEN without ever being revealed -- because applyState applies
    // the broken bitset BEFORE it reveals anything, and a dormant pile is not standing.
    // Asking `standing` here dropped the bit silently, reveal then put the heap back, and
    // clearing a street did not survive a reload.
    if (this.state[index] !== INTACT && this.state[index] !== DORMANT) return false

    this.state[index] = BROKEN
    // Shards before the piece goes: they are spawned from the transform the piece had,
    // which is still on hand either way, but doing it in this order keeps the two reads of
    // that matrix next to each other.
    if (!carried && !silent) this.debris?.spawn(this.matrices[index], this.material[index], { away })
    this.meshes.setVisible(this.pool[index], this.slot[index], false)
    if (this.targets?.[index]) this.grid?.remove(this.targets[index])
    // Disabled, never removed. The handle stays valid, the registry stays consistent, and
    // restoring is the same call with the other argument.
    this.colliders[index]?.setEnabled(false)
    return true
  }

  // A collapse arrives as twenty bytes -- [object_id, from_storey] -- and becomes a
  // hundred and fifty pieces here. The client already holds the surfaces, so expanding it
  // is a filter rather than a message. Roof and gable surfaces carry storey_count, which
  // is above every real storey, so "storey >= from" reaches them without a special case.
  collapse(fromStorey, silent = false) {
    // Roof and gable surfaces carry storey_count, which is above every real storey, so
    // "storey >= from" reaches them without a special case.
    const coming = this.spec.surfaces.filter((surface) => surface.storey >= fromStorey)

    // What is still standing, covered in slabs. Done before anything breaks, because the
    // tiling can only see what is standing and everything here is about to not be.
    //
    // Nothing falls on a silent restore: the pieces were broken in some earlier session,
    // possibly by somebody else, and raining masonry onto a street on every page load is
    // the same lie as re-staging their shards.
    const slabs = []
    if (!silent && this.chunkSize && this.falling) {
      for (const surface of coming) {
        for (const slab of tileSurface(surface, this.chunkSize, this.standingAt)) {
          slab.surface = surface
          slabs.push(slab)
        }
      }
    }

    // Every nth slab rather than the first n, so what tumbles is spread evenly through the
    // structure instead of being whichever surface the generator emitted first while the
    // rest puffs away. Since a house tiles to fewer slabs than the budget holds, the stride
    // is normally one and all of it comes down -- the thinning is what keeps a cathedral
    // from stalling the frame, not something a house should ever meet.
    const budget = this.falling?.capacity ?? 0
    const stride = budget > 0 && slabs.length > budget ? Math.ceil(slabs.length / budget) : 1

    // Which cells a slab has taken responsibility for. They still break individually, and
    // are still numbered and reported exactly as before -- they simply throw no shards of
    // their own, because the slab carrying them will throw those when it lands.
    const carried = new Uint8Array(this.pieceCount)
    let dropped = 0

    for (let n = 0; n < slabs.length; n += stride) {
      const slab = slabs[n]
      const matrix = chunkMatrix(
        slab.surface, slab.row, slab.col, slab.rows, slab.cols, SLAB_MATRIX, this.origin
      )
      slab.owner = this
      if (!this.falling.drop(matrix, slab.material, slab)) continue
      dropped += 1

      for (let r = 0; r < slab.rows; r += 1) {
        for (let c = 0; c < slab.cols; c += 1) {
          carried[slab.surface.off + (slab.row + r) * slab.surface.cols + slab.col + c] = 1
        }
      }
    }

    let count = 0
    for (const surface of coming) {
      const end = surface.off + surface.rows * surface.cols
      for (let index = surface.off; index < end; index += 1) {
        if (this.breakCell(index, null, silent, carried[index] === 1)) count += 1
      }
    }

    this.expectedSlabs = dropped
    this.landedSlabs = 0
    return count
  }

  // How much wreckage this collapse will eventually leave. Held rather than revealed,
  // because the heaps arrive as the pieces carrying them hit the ground.
  //
  // A restore has no slabs to wait for -- the house came down in some earlier session and
  // the wreckage simply IS there -- so with nothing in the air it all appears at once.
  expectRubble(total) {
    this.pendingRubble = total
    if (!this.expectedSlabs) return this.revealRubble(total)

    return 0
  }

  // One falling slab has landed. Reveal wreckage in proportion, so the site fills in as
  // the house comes apart and is complete the moment the last piece is down.
  slabLanded() {
    this.landedSlabs = (this.landedSlabs ?? 0) + 1
    if (!this.pendingRubble || !this.expectedSlabs) return 0

    const share = Math.min(1, this.landedSlabs / this.expectedSlabs)
    return this.revealRubble(Math.round(this.pendingRubble * share))
  }

  // Monotone, and that is the whole of the reconciliation design. This only ever breaks.
  // A piece we have already broken that the server thinks is standing stays broken, which
  // is what makes a rollback after a server restart invisible rather than a wall
  // flickering back into existence in front of the player who just drove through it.
  applyBroken(base64, silent = false) {
    if (!base64) return 0
    const binary = atob(base64)
    let count = 0
    for (let index = 0; index < this.pieceCount; index++) {
      const byte = binary.charCodeAt(index >> 3)
      if (byte & (1 << (index & 7)) && this.breakCell(index, null, silent)) count++
    }
    return count
  }

  // DORMANT -> INTACT, and NEVER BROKEN -> INTACT. That clause is the whole of why the
  // order of applyState's two halves does not matter: it applies the broken bitset first
  // and the collapse second, so without it, rejoining a match where heaps had been cleared
  // would put every one of them back on the street.
  reveal(index) {
    if (this.state[index] !== DORMANT) return false

    this.state[index] = INTACT
    this.health[index] = this.maxHealth[index]
    this.meshes.setVisible(this.pool[index], this.slot[index], true, this.matrices[index])
    this.meshes.tint(this.pool[index], this.slot[index], 1)
    this.colliders[index]?.setEnabled(true)
    if (this.grid && this.matrices[index]) {
      this.matrices[index].decompose(POSITION, ROTATION, SCALE)
      this.grid.insert(this.target(index), POSITION.x, POSITION.y, POSITION.z)
    }
    return true
  }

  // The first `count` heaps in index order -- the same order and the same count the server
  // works out from collapsed_from, so the two never disagree about which heaps exist.
  revealRubble(count) {
    const surface = this.spec.surfaces.find((s) => s.kind === "rubble")
    if (!surface) return 0

    // Outward from the middle, and in exactly the order Building::Rubble.pile_indices
    // returns -- the server gates damage on the revealed prefix, so revealing a different
    // subset would show heaps that cannot be cleared and hide heaps the server thinks are
    // there. For a partial collapse it would do so permanently.
    const order = pileOrder(surface)
    let revealed = 0

    for (let n = 0; n < order.length && n < count; n += 1) {
      if (this.reveal(order[n])) revealed += 1
    }
    return revealed
  }

  get rubbleCounts() {
    const counts = { dormant: 0, standing: 0, cleared: 0 }

    for (let index = 0; index < this.pieceCount; index += 1) {
      if (this.material[index] !== "rubble") continue

      if (this.state[index] === DORMANT) counts.dormant += 1
      else if (this.state[index] === INTACT) counts.standing += 1
      else if (this.state[index] === BROKEN) counts.cleared += 1
    }
    return counts
  }

  restore(index) {
    let restored = false
    for (const cell of this.block(index)) restored = this.restoreCell(cell) || restored
    return restored
  }

  restoreCell(index) {
    if (this.state[index] !== BROKEN) return false

    this.state[index] = INTACT
    this.health[index] = this.maxHealth[index]
    this.meshes.setVisible(this.pool[index], this.slot[index], true, this.matrices[index])
    this.meshes.tint(this.pool[index], this.slot[index], 1)
    this.colliders[index]?.setEnabled(true)
    if (this.grid && this.matrices[index]) {
      this.matrices[index].decompose(POSITION, ROTATION, SCALE)
      this.grid.insert(this.target(index), POSITION.x, POSITION.y, POSITION.z)
    }
    return true
  }

  get brokenCount() {
    let broken = 0
    for (let i = 0; i < this.state.length; i += 1) if (this.state[i] === BROKEN) broken += 1
    return broken
  }

  get standingCount() {
    let standing = 0
    for (let i = 0; i < this.state.length; i += 1) if (this.state[i] === INTACT) standing += 1
    return standing
  }

  dispose(colliderIndex) {
    for (const collider of this.colliders) {
      if (!collider) continue
      colliderIndex.delete(collider.handle)
      this.world.removeCollider(collider, false)
    }
    this.colliders.length = 0
  }
}

// Allocated per call rather than kept, because the caller iterates it and a shared
// array would be overwritten by a nested break.
const SINGLE_CELL = (index) => [ index ]

const SLAB_MATRIX = new THREE.Matrix4()

const POSITION = new THREE.Vector3()
const ROTATION = new THREE.Quaternion()
const SCALE = new THREE.Vector3()
