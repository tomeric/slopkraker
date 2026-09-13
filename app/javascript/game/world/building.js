import * as THREE from "three"
import { PROP_GROUPS } from "game/physics/groups"
import { eachBuildingCell, materialAt } from "game/world/surface"
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

export class Building {
  constructor({ RAPIER, world, spec, materials, meshes, colliderIndex, contactThreshold, spread = 0, debris = null, grid = null, rules = {} }) {
    this.spec = spec
    this.materials = materials
    this.meshes = meshes
    this.world = world
    this.contactThreshold = contactThreshold
    this.spread = spread
    this.debris = debris
    this.grid = grid
    this.rules = rules
    this.id = spec.id
    this.name = spec.name

    const count = spec.piece_count
    this.state = new Uint8Array(count)
    this.health = new Float32Array(count)
    this.maxHealth = new Float32Array(count)
    this.slot = new Int32Array(count).fill(-1)
    this.material = new Array(count)
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
  static countMaterials(spec, into = new Map()) {
    for (const surface of spec.surfaces) {
      for (let row = 0; row < surface.rows; row += 1) {
        for (let col = 0; col < surface.cols; col += 1) {
          const name = materialAt(surface, row, col)
          if (name === "void") continue
          into.set(name, (into.get(name) || 0) + 1)
        }
      }
    }
    return into
  }

  build(RAPIER, colliderIndex) {
    const surfaceIndex = new Map(this.spec.surfaces.map((surface, i) => [ surface, i ]))
    // Block ids are local to their surface, so they are rebased onto a building-wide id
    // as each surface is walked.
    const blockBase = new Map()

    eachBuildingCell(this.spec, (index, name, matrix, surface) => {
      this.material[index] = name
      this.surfaceOf[index] = surfaceIndex.get(surface)
      this.assignBlock(index, surface, blockBase)

      // A doorway. It holds an index so the arithmetic stays uniform, and nothing else.
      if (name === "void") {
        this.state[index] = ABSENT
        return
      }

      this.matrices[index] = matrix.clone()
      // Keyed by material, not per surface: a glass window in a brick wall has to break
      // like glass, not like the wall it is set into.
      const health = surface.hp[name] ?? 0
      this.health[index] = health
      this.maxHealth[index] = health
      this.slot[index] = this.meshes.add(name, matrix)
      this.colliders[index] = this.createCollider(RAPIER, matrix, surface, name, index, colliderIndex)

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

    this.health[index] -= amount
    if (this.health[index] > 0) {
      this.meshes.tint(this.material[index], this.slot[index], this.health[index] / this.maxHealth[index])
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

  breakCell(index, away = null) {
    if (!this.standing(index)) return false

    this.state[index] = BROKEN
    // Shards before the piece goes: they are spawned from the transform the piece had,
    // which is still on hand either way, but doing it in this order keeps the two reads of
    // that matrix next to each other.
    this.debris?.spawn(this.matrices[index], this.material[index], { away })
    this.meshes.setVisible(this.material[index], this.slot[index], false)
    if (this.targets?.[index]) this.grid?.remove(this.targets[index])
    // Disabled, never removed. The handle stays valid, the registry stays consistent, and
    // restoring is the same call with the other argument.
    this.colliders[index]?.setEnabled(false)
    return true
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
    this.meshes.setVisible(this.material[index], this.slot[index], true, this.matrices[index])
    this.meshes.tint(this.material[index], this.slot[index], 1)
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

const POSITION = new THREE.Vector3()
const ROTATION = new THREE.Quaternion()
const SCALE = new THREE.Vector3()
