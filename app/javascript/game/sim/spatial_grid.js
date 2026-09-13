// A uniform bucket grid over the XZ plane, for answering "what is near this point"
// without asking every object in the world.
//
// Buckets are XZ-only and span all of Y. Everything here stacks shallowly relative to the
// cell size -- a crate tower is a few metres, a cell is five -- so a third axis would add
// bookkeeping without removing candidates. The caller does an exact 3D distance test on
// what comes back anyway.
//
// Positions are cached here rather than read from the bodies. That is the whole point:
// Rapier lives on the wasm heap and every translation() is a boundary crossing, so a
// query that touched each candidate's body would cost more than the sweep it replaces.
// The interpolator already reads every moving body's transform once per step, so those
// positions are free for the taking.
//
// Static items are inserted once and never revisited, which is what makes this scale: a
// city's building pieces never move, so the per-frame cost stays proportional to the
// handful of things that do.

const OFFSET = 32768
const STRIDE = 65536

export class SpatialGrid {
  constructor({ cellSize = 5 } = {}) {
    this.cellSize = cellSize
    this.cells = new Map()
    this.records = new Map()
    // Only these are re-seated as they move; everything else is inserted once.
    this.dynamic = []
  }

  get size() {
    return this.records.size
  }

  key(ix, iz) {
    return (ix + OFFSET) * STRIDE + (iz + OFFSET)
  }

  cellOf(value) {
    return Math.floor(value / this.cellSize)
  }

  insert(item, x, y, z, { dynamic = false } = {}) {
    const record = { item, x, y, z, ix: this.cellOf(x), iz: this.cellOf(z), dynamic }
    this.records.set(item, record)
    this.bucket(record.ix, record.iz).push(record)
    if (dynamic) this.dynamic.push(record)
    return record
  }

  bucket(ix, iz) {
    const key = this.key(ix, iz)
    let cell = this.cells.get(key)
    if (!cell) {
      cell = []
      this.cells.set(key, cell)
    }
    return cell
  }

  // Cheap when nothing crossed a boundary, which is the common case: the position is
  // overwritten in place and the buckets are left alone.
  update(item, x, y, z) {
    const record = this.records.get(item)
    if (!record) return

    record.x = x
    record.y = y
    record.z = z

    const ix = this.cellOf(x)
    const iz = this.cellOf(z)
    if (ix === record.ix && iz === record.iz) return

    this.unbucket(record)
    record.ix = ix
    record.iz = iz
    this.bucket(ix, iz).push(record)
  }

  remove(item) {
    const record = this.records.get(item)
    if (!record) return

    this.unbucket(record)
    this.records.delete(item)
    if (record.dynamic) {
      const index = this.dynamic.indexOf(record)
      if (index >= 0) this.dynamic.splice(index, 1)
    }
  }

  unbucket(record) {
    const cell = this.cells.get(this.key(record.ix, record.iz))
    if (!cell) return

    const index = cell.indexOf(record)
    if (index >= 0) {
      const last = cell.pop()
      if (last !== record) cell[index] = last
    }
  }

  // Re-seats everything that moves. The caller supplies positions it already has, so this
  // never touches wasm.
  refreshDynamic(positionOf) {
    for (let i = this.dynamic.length - 1; i >= 0; i -= 1) {
      const record = this.dynamic[i]
      const at = positionOf(record.item)
      if (at) this.update(record.item, at.x, at.y, at.z)
    }
  }

  // Every item whose cell overlaps the disc of `outer` around (x, z), skipping cells that
  // lie wholly inside `inner`. An expanding shell only ever needs the band it just swept:
  // anything nearer was visited on an earlier tick and the caller's hit set has it.
  //
  // `visit` receives the item and its cached position, so a caller doing an exact distance
  // test never has to look the position up again.
  forEachInAnnulus(x, z, inner, outer, visit) {
    const size = this.cellSize
    const minX = this.cellOf(x - outer)
    const maxX = this.cellOf(x + outer)
    const minZ = this.cellOf(z - outer)
    const maxZ = this.cellOf(z + outer)
    const innerSquared = inner > 0 ? inner * inner : 0

    for (let ix = minX; ix <= maxX; ix += 1) {
      for (let iz = minZ; iz <= maxZ; iz += 1) {
        const cell = this.cells.get(this.key(ix, iz))
        if (!cell || cell.length === 0) continue

        // The cell's farthest corner from the centre. Inside `inner` means every item in
        // it was already reached.
        if (innerSquared > 0) {
          const fx = Math.max(Math.abs(x - ix * size), Math.abs(x - (ix + 1) * size))
          const fz = Math.max(Math.abs(z - iz * size), Math.abs(z - (iz + 1) * size))
          if (fx * fx + fz * fz <= innerSquared) continue
        }

        // Backwards, because visit() is allowed to remove things from this very cell. A
        // blast destroys what it reaches, and a destroyed piece leaves the grid at once --
        // and because damage spreads, it takes its neighbours with it, several of which
        // are usually in this same cell.
        //
        // remove() swaps the last record into the hole. Walking down means that record has
        // already been visited, so nothing is skipped or seen twice. But the cell can
        // shrink past the index we started from, so the bound is re-checked every step:
        // without that, cell[i] reads undefined and the whole sweep throws, which loses
        // every target the blast had not reached yet.
        for (let i = cell.length - 1; i >= 0; i -= 1) {
          if (i >= cell.length) continue

          const record = cell[i]
          if (record) visit(record.item, record.x, record.y, record.z)
        }
      }
    }
  }

  clear() {
    this.cells.clear()
    this.records.clear()
    this.dynamic.length = 0
  }
}
