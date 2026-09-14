import * as THREE from "three"
import { cellMatrix } from "game/world/surface"

// Where one heap of garbage actually sits.
//
// The grid rubble is generated on is coarse -- 2m cells against the building's own 1m --
// so a heap drawn to fill its cell would read as a tiled floor of rubbish rather than as
// scattered wreckage. This shrinks it, spins it and nudges it off centre.
//
// Every one of those comes from the cell's own coordinates and the surface's seed, and
// NEVER from Math.random. That is the whole reason two players see rubble in the same place
// without a byte of it going over the wire: the server decided which cells hold a heap when
// it generated the surface, and both clients work out where those heaps sit from numbers
// they already hold. The server never computes this at all and does not need to.
export function rubbleMatrix(surface, row, col, target, origin, rules = {}) {
  const jitter = rules.jitter ?? 0.3
  const scale = rules.scale ?? 0.85
  const tilt = rules.tilt ?? 0.28
  const mound = rules.mound ?? 0.7

  cellMatrix(surface, row, col, target, origin)
  target.decompose(POSITION, ROTATION, SCALE)

  // Along the surface's own axes, so a nudge stays in the plane the heaps lie on.
  U.set(1, 0, 0).applyQuaternion(ROTATION)
  V.set(0, 1, 0).applyQuaternion(ROTATION)
  POSITION
    .addScaledVector(U, noise(surface, row, col, 11) * jitter * SCALE.x)
    .addScaledVector(V, noise(surface, row, col, 17) * jitter * SCALE.y)

  // Spun about the heap's own up, then LEANED off it. The spin alone left every heap
  // perfectly level, which is what a paving slab is; a heap that fell off a building is
  // not level, and the lean is what says so.
  N.set(0, 0, 1).applyQuaternion(ROTATION)
  SPIN.setFromAxisAngle(N, noise(surface, row, col, 23) * Math.PI)
  ROTATION.premultiply(SPIN)

  LEAN_AXIS
    .copy(U)
    .multiplyScalar(noise(surface, row, col, 41))
    .addScaledVector(V, noise(surface, row, col, 43))
  if (LEAN_AXIS.lengthSq() > 1e-6) {
    SPIN.setFromAxisAngle(LEAN_AXIS.normalize(), noise(surface, row, col, 47) * tilt)
    ROTATION.premultiply(SPIN)
  }

  // Rubble piles toward the middle of what fell rather than settling evenly, so the site
  // reads as a mound rather than as a field of identical lumps. Volume is not conserved by
  // this; it is a silhouette, and the honest volume is already in the depth Ruby computed.
  const vary = 1 + noise(surface, row, col, 31) * 0.25
  const heap = vary * (1 + mound * (1 - centreDistance(surface, row, col)))

  SCALE.set(SCALE.x * scale * vary, SCALE.y * scale * vary, SCALE.z * heap)
  // Lifted by however much the mound grew it, so a taller heap still stands ON the ground
  // rather than sinking its extra depth into it.
  POSITION.addScaledVector(N, (SCALE.z - Math.abs(surface.t)) / 2)

  return target.compose(POSITION, ROTATION, SCALE)
}

// 0 at the middle of the grid, 1 at its corners.
function centreDistance(surface, row, col) {
  const dx = (col + 0.5) / surface.cols - 0.5
  const dy = (row + 0.5) / surface.rows - 0.5
  return Math.min(1, Math.hypot(dx, dy) * 2)
}

// -1..1, deterministic in the surface's seed and offset and the cell's coordinates. The
// offset is in there so that two surfaces with identical grids -- which a street of
// identical houses would have -- do not come out laid out identically.
function noise(surface, row, col, salt) {
  let h = ((surface.seed ?? 0) + 1) * 73856093
  h ^= (surface.off + 1) * 19349663
  h ^= (row + 1) * 83492791
  h ^= (col + 1) * salt
  return ((Math.abs(h) % 10000) / 10000) * 2 - 1
}

const POSITION = new THREE.Vector3()
const ROTATION = new THREE.Quaternion()
const SCALE = new THREE.Vector3()
const SPIN = new THREE.Quaternion()
const U = new THREE.Vector3()
const V = new THREE.Vector3()
const N = new THREE.Vector3()
const LEAN_AXIS = new THREE.Vector3()
