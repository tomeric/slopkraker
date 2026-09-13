import { Building } from "game/world/building"
import { PieceMeshes } from "game/render/piece_meshes"

// Every building in the world, and the instanced meshes they share.
//
// The meshes are shared deliberately: one InstancedMesh per material across ALL buildings
// rather than per building. A street of houses is then still one draw call per material
// instead of one per material per house, which is the difference that decides whether a
// city is possible at all.
export class Buildings {
  constructor({ RAPIER, world, scene, spec, materials, colliderIndex }) {
    this.list = []
    this.byId = new Map()

    const specs = spec.arena.buildings || []
    this.meshes = new PieceMeshes(scene, materials)
    if (specs.length === 0) return

    // Counted across every building first, because an InstancedMesh is allocated once at
    // its final capacity and cannot grow afterwards.
    const counts = new Map()
    for (const building of specs) Building.countMaterials(building, counts)
    this.meshes.allocate(counts)

    for (const buildingSpec of specs) {
      const building = new Building({
        RAPIER, world, spec: buildingSpec, materials,
        meshes: this.meshes, colliderIndex,
        contactThreshold: spec.rules.impact_force_threshold
      })
      this.list.push(building)
      this.byId.set(building.id, building)
    }

    this.meshes.finalise()
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
    this.meshes.dispose()
    this.list = []
    this.byId.clear()
  }
}
