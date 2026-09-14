// Rapier interaction groups. These are engine mechanics rather than game tuning, so they
// live here rather than in the Ruby spec.
//
// A pair collides only if BOTH directions pass:
//   (A.membership & B.filter) && (B.membership & A.filter)
// which is what lets a rocket ignore the vehicle that fired it while still hitting
// everything else -- including other players' vehicles.
export const LAYER = {
  WORLD: 1 << 0,
  PROP: 1 << 1,
  OWN_VEHICLE: 1 << 2,
  OTHER_VEHICLE: 1 << 3,
  ROCKET: 1 << 4,
  DEBRIS: 1 << 5
}

export const ALL = Object.values(LAYER).reduce((acc, bit) => acc | bit, 0)

export function groups(membership, filter) {
  return ((membership & 0xffff) << 16) | (filter & 0xffff)
}

export const WORLD_GROUPS = groups(LAYER.WORLD, ALL)
export const PROP_GROUPS = groups(LAYER.PROP, ALL)
export const DEBRIS_GROUPS = groups(LAYER.DEBRIS, ALL & ~LAYER.ROCKET)

// A piece of a collapsing building on its way down. On the DEBRIS layer, but deaf to its
// own kind, and that exclusion is the whole reason this is not just DEBRIS_GROUPS.
//
// A falling piece shatters on the first thing it touches. Condemned panels start out flush
// against the panels that were beside them, so if they could touch each other the entire
// storey would burst on its first frame and nothing would ever be seen to fall. Deaf to
// each other, they meet the ground, the masonry still standing, and your car -- which is
// everything worth hitting.
export const FALLING_GROUPS = groups(LAYER.DEBRIS, ALL & ~LAYER.ROCKET & ~LAYER.DEBRIS)

export function vehicleGroups(owner) {
  const layer = owner === "local" ? LAYER.OWN_VEHICLE : LAYER.OTHER_VEHICLE
  return groups(layer, ALL)
}

// A part that reaches well past the bodywork with nothing drawn to explain it -- the bull
// bar while a drift has it swung out. Clipping a wall with an invisible wing reads as the
// car hitting thin air, so while it is out the part only meets things worth hitting.
// Walls become destructible props in time, at which point the PROP bit catches them like
// anything else.
export function reachingPartGroups(owner) {
  const layer = owner === "local" ? LAYER.OWN_VEHICLE : LAYER.OTHER_VEHICLE
  return groups(layer, ALL & ~LAYER.WORLD)
}

// Whether a collision-groups mask still meets the arena itself. Kept here with the bit
// layout rather than unpacked by every caller that wants to know.
export function catchesWorld(collisionGroups) {
  return (collisionGroups & LAYER.WORLD) !== 0
}

// A rocket ignores only the vehicle that launched it.
export function rocketGroups(owner) {
  const own = owner === "local" ? LAYER.OWN_VEHICLE : LAYER.OTHER_VEHICLE
  return groups(LAYER.ROCKET, ALL & ~own)
}
