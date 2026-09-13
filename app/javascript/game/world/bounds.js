import { WORLD_GROUPS } from "game/physics/groups"

// The hard edges of the world: four invisible fixed colliders standing on its boundary.
//
// Invisible rather than drawn, because a wall you can see is a wall the world appears to
// end at. Nothing is rendered here at all -- these exist purely to be hit.
//
// Tall enough that jump jets cannot clear them, and thick enough that nothing tunnels
// through at speed. Thickness is the real defence: a fast rocket moves about half a metre
// per physics step, so a thin wall could be on the far side of the collider before the
// solver ever sees a contact.
const HEIGHT = 60.0
const THICKNESS = 4.0

export function createWorldBounds(RAPIER, world, bounds) {
  if (!bounds) return []

  const [ minX, minZ, maxX, maxZ ] = bounds
  const width = maxX - minX
  const depth = maxZ - minZ
  const midX = (minX + maxX) / 2
  const midZ = (minZ + maxZ) / 2
  const half = THICKNESS / 2
  const y = HEIGHT / 2

  // Each wall is placed with its inner face exactly on the boundary, so the playable area
  // is the bounds themselves rather than the bounds plus however thick the wall happens
  // to be. The side walls are inset by the thickness so the corners do not overlap.
  return [
    [ midX, y, minZ - half, width + THICKNESS * 2, HEIGHT, THICKNESS ],
    [ midX, y, maxZ + half, width + THICKNESS * 2, HEIGHT, THICKNESS ],
    [ minX - half, y, midZ, THICKNESS, HEIGHT, depth ],
    [ maxX + half, y, midZ, THICKNESS, HEIGHT, depth ]
  ].map(([ x, cy, z, w, h, d ]) =>
    world.createCollider(
      RAPIER.ColliderDesc.cuboid(w / 2, h / 2, d / 2)
        .setTranslation(x, cy, z)
        .setCollisionGroups(WORLD_GROUPS)
        .setFriction(0.4)
        .setRestitution(0.1)
    )
  )
}
