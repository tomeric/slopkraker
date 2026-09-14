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
  const scale = rules.scale ?? 0.55
  const height = rules.height ?? 0.6

  cellMatrix(surface, row, col, target, origin)
  target.decompose(POSITION, ROTATION, SCALE)

  // Along the surface's own axes, so a nudge stays in the plane the heaps lie on.
  U.set(1, 0, 0).applyQuaternion(ROTATION)
  V.set(0, 1, 0).applyQuaternion(ROTATION)
  POSITION
    .addScaledVector(U, noise(surface, row, col, 11) * jitter * SCALE.x)
    .addScaledVector(V, noise(surface, row, col, 17) * jitter * SCALE.y)

  SPIN.setFromAxisAngle(
    N.set(0, 0, 1).applyQuaternion(ROTATION),
    noise(surface, row, col, 23) * Math.PI
  )
  ROTATION.premultiply(SPIN)

  const vary = 1 + noise(surface, row, col, 31) * 0.25
  SCALE.set(SCALE.x * scale * vary, SCALE.y * scale * vary, SCALE.z * height)

  return target.compose(POSITION, ROTATION, SCALE)
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
