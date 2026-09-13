// Everything that moves and therefore needs interpolating between the last two physics
// states. Physics runs at the rate Ruby specifies; the display runs at whatever the
// monitor does. Without this the car would visibly step.
//
// Static geometry is deliberately absent. It never moves, so an entry for it would be
// pure per-frame cost -- which matters a great deal once the world is a city rather than
// an arena.
//
// Removal is O(1) by swap, keyed on the rigid body itself. A prop breaking mid-step has
// to leave the list in the same breath its body is freed: leaving it in means the next
// readBack() calls translation() on released wasm memory, which traps and poisons the
// whole Rapier instance.

// The vehicle needs the same prev/curr machinery but is not a plain body-and-mesh pair --
// it renders through a VehicleView and keeps its own interpolated transform -- so these
// three are exported for it to build on rather than hidden inside the class.
export function createEntry({ body, mesh = null, position, quaternion }) {
  const pos = position || mesh.position
  const rot = quaternion || mesh.quaternion

  return {
    body,
    mesh,
    prevPos: pos.clone(),
    currPos: pos.clone(),
    prevRot: rot.clone(),
    currRot: rot.clone(),
    // Reused across steps: Rapier writes into these rather than allocating a vector per
    // body per step.
    scratchVec: { x: 0, y: 0, z: 0 },
    scratchRot: { x: 0, y: 0, z: 0, w: 1 }
  }
}

export function savePrevious(entry) {
  entry.prevPos.copy(entry.currPos)
  entry.prevRot.copy(entry.currRot)
}

export function readBack(entry) {
  const t = entry.body.translation(entry.scratchVec)
  const r = entry.body.rotation(entry.scratchRot)
  entry.currPos.set(t.x, t.y, t.z)
  entry.currRot.set(r.x, r.y, r.z, r.w)
}

export class Interpolator {
  constructor() {
    this.entries = []
    this.byBody = new Map()
  }

  get size() {
    return this.entries.length
  }

  track({ body, mesh }) {
    const entry = createEntry({ body, mesh })
    entry.slot = this.entries.length
    this.entries.push(entry)
    this.byBody.set(body, entry)
    return entry
  }

  untrack(body) {
    const entry = this.byBody.get(body)
    if (!entry) return

    this.byBody.delete(body)
    const last = this.entries.pop()
    if (last !== entry) {
      last.slot = entry.slot
      this.entries[entry.slot] = last
    }
  }

  beginStep() {
    for (const entry of this.entries) savePrevious(entry)
  }

  endStep() {
    for (const entry of this.entries) readBack(entry)
  }

  interpolate(alpha) {
    for (const entry of this.entries) {
      entry.mesh.position.lerpVectors(entry.prevPos, entry.currPos, alpha)
      entry.mesh.quaternion.slerpQuaternions(entry.prevRot, entry.currRot, alpha)
    }
  }

  clear() {
    this.entries = []
    this.byBody.clear()
  }
}
