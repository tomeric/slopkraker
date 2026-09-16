import { WORLD_GROUPS } from "game/physics/groups"
import { physicsHeights } from "game/world/terrain"

// One fixed heightfield collider per tile, on the WORLD layer like the ground slab it
// replaces. The wheel rays' filter includes WORLD, so they land on it with no change.
//
// ColliderDesc.heightfield takes CELL counts, so n - 1, and a heights array of n * n in
// column-major order -- physicsHeights does the transpose. The field is centred on its
// own origin and spans +/- scale/2 on x and z, so it is translated to the tile's centre.
// FIX_INTERNAL_EDGES stops a body catching on the edges between triangles; it does not
// change which diagonal the cells are split on.
export function createTerrainColliders(RAPIER, world, terrain, rules, colliderIndex, threshold) {
  const n = terrain.n
  const size = terrain.tileSize
  const colliders = []

  for (const tile of terrain.list) {
    const desc = RAPIER.ColliderDesc
      .heightfield(n - 1, n - 1, physicsHeights(tile, n), { x: size, y: 1, z: size }, RAPIER.HeightFieldFlags.FIX_INTERNAL_EDGES)
      .setTranslation(tile.originX + size / 2, 0, tile.originZ + size / 2)
      .setCollisionGroups(WORLD_GROUPS)
      .setFriction(rules.friction)
      .setRestitution(rules.restitution)
      .setActiveEvents(RAPIER.ActiveEvents.CONTACT_FORCE_EVENTS)
      .setContactForceEventThreshold(threshold)

    const collider = world.createCollider(desc)
    colliderIndex.set(collider.handle, { kind: "terrain", name: "terrain", destructible: false, body: null })
    colliders.push(collider)
  }
  return colliders
}

// The height of the PHYSICS ground under a point: a ray cast straight down from above
// the highest sample, allowed to hit terrain colliders and nothing else. This is one half
// of __arenaTerrainProbe; the other half reads the drawn triangles.
let ray = null

export function castTerrain(RAPIER, world, colliderIndex, terrain, x, z) {
  ray ||= new RAPIER.Ray({ x: 0, y: 0, z: 0 }, { x: 0, y: -1, z: 0 })
  ray.origin.x = x
  ray.origin.y = terrain.max + 50
  ray.origin.z = z

  const hit = world.castRay(
    ray, terrain.max - terrain.min + 100, true, undefined, undefined, undefined, undefined,
    (collider) => colliderIndex.get(collider.handle)?.kind === "terrain"
  )
  return hit ? ray.origin.y - hit.timeOfImpact : null
}
