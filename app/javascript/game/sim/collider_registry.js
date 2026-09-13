// What did I just hit? Every collider in the world resolves through here, and a miss is
// silent -- handleContacts returns early when either side is unknown, so anything that
// forgets to register simply never registers a hit.
//
// Entries are shaped by what registered them:
//
//   static geometry   { kind, name, destructible: false, body: null }
//   props             { kind, name, destructible: true, body, prop }
//   vehicle parts     { kind, name, part, vehicle, owner }
//   rockets           { kind: "rocket", rocket }
//
// The `owner` field is what handleContacts uses to decide which side of a contact is the
// attacker, so it is only ever set on things that can deal damage.
//
// This is a Map by another name today, and deliberately so: it exists to give the lookup
// a place to live before the world grows past what a Map should be asked to hold. Rapier
// hands out small, dense, recycled collider handles, so the population that will dominate
// -- thousands of building pieces -- can move behind a typed-array fast path here without
// a single caller changing. Handle recycling is why delete() must actually delete: a
// stale entry would answer for whatever collider inherits the handle next.
export class ColliderRegistry {
  constructor() {
    this.byHandle = new Map()
  }

  get size() {
    return this.byHandle.size
  }

  get(handle) {
    return this.byHandle.get(handle)
  }

  set(handle, entry) {
    this.byHandle.set(handle, entry)
    return this
  }

  delete(handle) {
    return this.byHandle.delete(handle)
  }

  has(handle) {
    return this.byHandle.has(handle)
  }

  clear() {
    this.byHandle.clear()
  }
}
