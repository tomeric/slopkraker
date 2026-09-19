import { Building } from "game/world/building"
import { PieceMeshes } from "game/render/piece_meshes"
import { Patterns } from "game/fracture/patterns"
import { Debris } from "game/render/debris"
import { FallingPieces } from "game/world/falling_pieces"
import { lumpGeometry, chunkGeometry, isFragmentPool, pileOrder, SHAPES } from "game/world/rubble"
import { isWedgePool, wedgeGeometry } from "game/world/gables"
import { eaves, PITCHED } from "game/world/fittings"
import { Remnants } from "game/render/remnants"
import { baseMaterial } from "game/render/piece_meshes"

// Every building in the world, and the instanced meshes they share.
//
// The meshes are shared deliberately: one InstancedMesh per material across ALL buildings
// rather than per building. A street of houses is then still one draw call per material
// instead of one per material per house, which is the difference that decides whether a
// city is possible at all.
export class Buildings {
  // `ground` is (x, z) => height for a world with terrain, or null; everything that lays
  // something on the ground takes it and reproduces its flat-world behaviour without it.
  constructor({ RAPIER, world, scene, spec, materials, colliderIndex, grid, ground = null, looks = null, onDamage = null }) {
    this.list = []
    this.byId = new Map()

    const specs = spec.arena.buildings || []
    // The textures every pool is dressed in, and the material a falling slab is drawn
    // with. It paints nothing at `low` quality and dresses nothing then either, so a world
    // built without one and a world built with a disabled one are drawn the same.
    this.meshes = new PieceMeshes(scene, materials, { looks })
    this.patterns = new Patterns(materials)
    const debrisRules = spec.rules.debris || {}
    this.debris = new Debris({ scene, materials, patterns: this.patterns, rules: debrisRules, ground })
    // Built whether or not there are buildings, so the engine can wire its drain hook and
    // its telemetry to something real on a world made of nothing but ground.
    this.falling = new FallingPieces({
      RAPIER, world, scene, colliderIndex, materials, debris: this.debris,
      rules: spec.rules.collapse?.fall, looks
    })
    const rubbleRules = spec.rules.collapse?.rubble || {}
    // How far the tiles reach past the wall. Held on the instance as well as passed down,
    // because the eaves probe needs the same number the buildings were built with.
    this.roofRules = spec.rules.roof || {}
    // Built whether or not there are buildings, for the same reason the falling pool is.
    this.remnants = new Remnants({ scene, materials, rules: rubbleRules.remnants, sweep: debrisRules, ground })
    if (specs.length === 0) return

    // Counted across every building first, because an InstancedMesh is allocated once at
    // its final capacity and cannot grow afterwards. A heap counts its lump and every
    // chunk in it.
    const counts = new Map()
    for (const building of specs) Building.countMaterials(building, counts, rubbleRules, this.roofRules)
    // Before allocate, and that ordering is the contract: a pool is handed its geometry
    // when its InstancedMesh is built and cannot be given a different one afterwards.
    const shapes = rubbleRules.shapes ?? SHAPES
    for (let variant = 0; variant < shapes; variant += 1) {
      this.meshes.useShape(`rubble#${variant}`, lumpGeometry(variant))
    }
    // One shape for every pool that is not drawn from a plain material's own geometry: a
    // chunk for wreckage (named for the material, so its colour, opacity and health are the
    // material's; only the shape is this file's) and a wedge for every material that has a
    // gable (the cap that makes the stair meet the roof; only the shape is gables.js's).
    for (const pool of counts.keys()) {
      if (isFragmentPool(pool)) this.meshes.useShape(pool, chunkGeometry(materials[baseMaterial(pool)]?.chunk))
      else if (isWedgePool(pool)) this.meshes.useShape(pool, wedgeGeometry())
    }
    this.meshes.allocate(counts)
    // Before the loop starts, so the first explosion is not also the first tessellation.
    // By MATERIAL, not by pool: `rubble#3` and `brick#rubble` break as rubble and brick,
    // and baking a pattern per pool was a dozen needless tessellations at boot.
    this.patterns.warm(new Set([ ...counts.keys() ].map(baseMaterial)))

    for (const buildingSpec of specs) {
      const building = new Building({
        RAPIER, world, spec: buildingSpec, materials,
        meshes: this.meshes, colliderIndex,
        contactThreshold: spec.rules.impact_force_threshold,
        spread: spec.rules.damage.spread || 0,
        debris: this.debris,
        falling: this.falling,
        chunk: spec.rules.collapse?.fall?.chunk,
        rubbleRules,
        // The SAME object countMaterials was handed above: the eaves pool was sized by
        // counting what these rules place, and PieceMeshes.add does not bounds-check.
        roofRules: this.roofRules,
        remnants: this.remnants,
        grid,
        rules: spec.rules.damage,
        ground,
        palettes: spec.palettes || {},
        lookRules: spec.rules.looks || {},
        onDamage
      })
      this.list.push(building)
      this.byId.set(building.id, building)
    }

    this.meshes.finalise()
  }

  update(dt) {
    this.debris.update(dt)
    this.falling.update(dt)
    this.remnants.update(dt)
    for (const building of this.list) building.update(dt)
  }

  // For the tests: does the roof actually cover the wall it sits on?
  //
  // The claim worth asserting is a HORIZONTAL reach, and nothing weaker. A wall straddles
  // its own plane, so half its thickness stands outside the line a roof plane starts on;
  // the overhang runs DOWN THE SLOPE, so what covers that half is only its horizontal
  // component -- EAVES_OVERHANG * cos(pitch), and v is a unit vector up the slope, so the
  // cosine is the length of v's own horizontal part. Counting instances instead would go
  // green on a one-millimetre lip, which is the fault this whole thing exists to fix.
  //
  // HALF THE THICKEST WALL OF THE SAME BUILDING IS A STAND-IN for the particular wall
  // under a particular plane, deliberately. Matching the two means intersecting a sloped
  // rectangle against a ring of walls at a dozen bearings, for a bar that could only ever
  // get easier: every wall of the building is at most this thick, so an overhang clearing
  // half of the thickest clears half of any of them. It is sufficient, and it is honest
  // about being the strict end of the range.
  //
  // Per-plane detail comes back with it, so a failure says WHICH plane fell short.
  eavesReach() {
    let planes = 0
    let boxes = 0
    let short = 0
    let reach = Infinity
    let drop = Infinity
    let need = 0
    const shortest = []

    for (const building of this.list) {
      let half = 0
      for (const surface of building.spec.surfaces) {
        if (surface.kind === "wall") half = Math.max(half, surface.t / 2)
      }

      for (const surface of building.spec.surfaces) {
        // Every PITCHED plane is in scope, whatever the overhang did about it -- a plane
        // that got none is short by definition, since the sky over its wall is the fault
        // being measured. That includes one Ruby flagged `fittings: false`, of which no
        // pitched plane exists today; if one ever does, this says so rather than quietly
        // exempting it.
        if (surface.kind !== "roof") continue
        if (Math.abs(surface.v[1]) < PITCHED) continue
        planes += 1
        need = Math.max(need, half)

        // Read off the boxes that were actually BUILT, not re-derived from the constant:
        // every column of the plane gets the same v0 and sv, so the first says it. A v0
        // of the wrong sign would put the tiles up by the ridge, and comes out at zero
        // here rather than passing on the constant's own magnitude.
        const built = eaves(surface, this.roofRules)
        boxes += built.length
        // How far past the plane's bottom edge (v = 0) its far edge reaches, down the
        // slope. Clamped at zero: an overhang pointing the wrong way covers nothing, it
        // does not cover a negative amount.
        const along = built.length ? Math.max(0, -(built[0].v0 - built[0].sv / 2)) : 0
        // v is a unit vector up the slope, so its horizontal part is cos(pitch) and its y
        // is sin(pitch). Only the horizontal covers the wall; the vertical is carried too
        // because it is what says the tiles went DOWN rather than up.
        const horizontal = along * Math.hypot(surface.v[0], surface.v[2])
        reach = Math.min(reach, horizontal)
        drop = Math.min(drop, along * Math.abs(surface.v[1]))
        if (horizontal > half) continue

        short += 1
        // Capped: a world of forty-eight rows that regressed would otherwise return a
        // list nobody can read in a failure message.
        if (shortest.length < 8) {
          shortest.push({ building: building.id, off: surface.off, reach: horizontal, need: half })
        }
      }
    }

    return {
      planes, boxes, short, need, shortest,
      overhang: this.roofRules?.eaves_overhang ?? 0,
      reach: planes ? reach : 0,
      drop: planes ? drop : 0
    }
  }

  // Bodies, so their meshes are read back like any other simulated thing. Called from the
  // render pass beside the prop debris, which does exactly this for the same reason.
  sync() {
    this.falling.sync()
  }

  // A car's box has swept through here: the small stuff inside it -- shards and the chunks
  // a cleared heap left -- is kicked out of the way. Nothing with a body is touched; the
  // heaps themselves are pieces and break the way pieces break.
  sweepVehicle(frame) {
    this.debris.sweepVehicle(frame)
    this.remnants.sweepVehicle(frame)
  }

  // A blast's shell has grown from `inner` to `outer`: the small stuff in that band is
  // thrown outward.
  blastDebris(at, inner, outer) {
    this.debris.sweepBlast(at, inner, outer)
    this.remnants.sweepBlast(at, inner, outer)
  }

  // Cumulative, and the still-visible subset. The two together say that debris was
  // kicked AND that kicked debris goes away.
  get debrisKicked() {
    return this.debris.kicked + this.remnants.kicked
  }

  get debrisKickedLive() {
    return this.debris.kickedLive + this.remnants.kickedLive
  }

  // What the server says is gone. Everything below is monotone -- it only ever breaks --
  // so applying the same message twice costs nothing and a break this client already
  // predicted is simply confirmed.
  applyBreaks(broken) {
    for (const [ objectId, pieceIndex ] of broken || []) {
      this.byId.get(objectId)?.break(pieceIndex)
    }
  }

  // One bay of one building. A terrace comes down a dwelling at a time, and a world of
  // single-bay houses says 0 for ever.
  applyCollapse(objectId, fromStorey, bay = 0) {
    const building = this.byId.get(objectId)
    if (!building) return 0

    const count = building.collapse(bay, fromStorey)
    // Owed, not given. The heaps appear as the slabs carrying them land -- which is what
    // stops a wall section falling through the rubble it is about to become.
    building.expectRubble(bay, this.revealedRubble(building, fromStorey, bay))
    return count
  }

  // The same arithmetic the server runs in Building::Rubble.revealed_count, over the bay's
  // own heaps: a bay gutted to the ground leaves all of its wreckage, one that lost only
  // its top floor a proportional share, and the dwelling still standing next door leaves
  // none at all. Both sides work it out from the storey it came down from and the storey
  // count, which they already hold, so it never goes on the wire.
  revealedRubble(building, fromStorey, bay = 0) {
    const storeys = building.spec.storeys
    if (!storeys || fromStorey === null || fromStorey === undefined) return 0

    const surface = building.spec.surfaces.find((s) => s.kind === "rubble")
    if (!surface) return 0

    const total = pileOrder(surface, surface.bays ? bay : null).length
    return Math.round(total * (storeys - fromStorey) / storeys)
  }

  // Silent, unlike applyBreaks. This is the world as it already was -- broken in some
  // earlier session, possibly by somebody else -- so the pieces are simply absent. Running
  // it loud meant every page load re-staged a demolition, and a persistent world that
  // explodes each time you open it does not read as persistence at all.
  applyState(objects) {
    for (const entry of objects || []) {
      const building = this.byId.get(entry.id)
      if (!building) continue

      building.applyBroken(entry.broken, true)
      // A map of bay to the storey that bay came down from, keyed as JSON hands it over.
      // An empty map -- or none at all -- is a building still standing.
      for (const [ bay, storey ] of Object.entries(entry.collapsed || {})) {
        building.collapse(Number(bay), storey, true)
        // AFTER applyBroken, and harmlessly so. Revealing only moves DORMANT -> INTACT, so
        // a heap cleared in some earlier session stays cleared -- which is what makes the
        // order of these two irrelevant rather than load-bearing.
        building.revealRubble(Number(bay), this.revealedRubble(building, storey, Number(bay)))
      }
    }
  }

  get debrisSpawned() {
    return this.debris.spawnedTotal
  }

  get fallingCount() {
    return this.falling.count
  }

  get fallingCells() {
    return this.falling.cellCount
  }

  // Reserved, on the ground, and cleared away. An intact world has only the first.
  get rubbleCounts() {
    return this.list.reduce((total, building) => {
      const counts = building.rubbleCounts
      return {
        dormant: total.dormant + counts.dormant,
        standing: total.standing + counts.standing,
        cleared: total.cleared + counts.cleared
      }
    }, { dormant: 0, standing: 0, cleared: 0 })
  }

  get debrisCount() {
    return this.debris.count
  }

  // Chunks left lying by cleared heaps, still visible. Zero once they have all faded.
  get remnantCount() {
    return this.remnants.count
  }

  get pieceCount() {
    return this.list.reduce((total, building) => total + building.pieceCount, 0)
  }

  get brokenCount() {
    return this.list.reduce((total, building) => total + building.brokenCount, 0)
  }

  get standingCount() {
    return this.list.reduce((total, building) => total + building.standingCount, 0)
  }

  find(id) {
    return this.byId.get(id) || this.list[0]
  }

  readout() {
    return this.list.map((building) => ({
      id: building.id,
      name: building.name,
      pieces: building.pieceCount,
      standing: building.standingCount,
      broken: building.brokenCount
    }))
  }

  dispose(colliderIndex) {
    for (const building of this.list) building.dispose(colliderIndex)
    this.falling.dispose()
    this.debris.dispose()
    this.remnants.dispose()
    this.patterns.dispose()
    this.meshes.dispose()
    this.list = []
    this.byId.clear()
  }
}
