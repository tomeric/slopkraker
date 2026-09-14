import * as THREE from "three"
import { cellMatrix, materialAt } from "game/world/surface"

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
  const jitter = rules.jitter ?? 0.55
  const scale = rules.scale ?? 0.85
  const tilt = rules.tilt ?? 0.28
  const falloff = rules.falloff ?? 2.5
  const edge = rules.edge ?? 0.06
  const spread = rules.spread ?? 0.55
  const sink = rules.sink ?? [ 0.05, 0.45 ]

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

  // Rubble piles toward the middle of what fell. A dome, and a VOLUME CONSERVING one: the
  // profile is divided by its own mean over the heaps, so the material Ruby computed is
  // neither created nor destroyed -- it is simply put where a pile puts it instead of being
  // spread flat. That is the whole difference between a pile of debris and a bumpy area,
  // and it is free.
  const vary = 1 + noise(surface, row, col, 31) * spread
  const heap = vary * dome(surface, row, col, falloff, edge) / domeMean(surface, falloff, edge)

  // Plan proportion, per heap rather than per shape, and area preserving -- so some lumps
  // are long and narrow and others nearly square without any of them covering more ground
  // than the coverage model counted on. This is where the per-variant stretch went when the
  // geometry was normalised.
  const aspect = 1 + noise(surface, row, col, 61) * (rules.aspect ?? 0.15)
  SCALE.set(SCALE.x * scale * vary * aspect, SCALE.y * scale * vary / aspect, SCALE.z * heap)

  // Lifted by however much the mound grew it, so a taller heap still stands ON the ground
  // rather than sinking its extra depth into it -- and then pushed back DOWN by its own
  // sink, because rubble settles into the ground it lands on and a lump resting exactly on
  // the surface reads as an object that was placed there.
  //
  // The sink is bounded well short of the two thirds that would bury a heap: a third of it
  // has to stand proud or it stops being something you have to get around.
  //
  // Applied along WORLD UP and not along the surface normal. The rubble grid's normal is
  // u x v = (0, -1, 0), which points straight DOWN -- so lifting along it buried the heap
  // and sinking along it floated it, and the two errors were quiet enough to look almost
  // right. The grid is always flat on the ground, so world up is both correct and honest.
  const buried = sink[0] + ((noise(surface, row, col, 59) + 1) / 2) * (sink[1] - sink[0])
  POSITION.y += (SCALE.z - Math.abs(surface.t)) / 2 - SCALE.z * buried

  return target.compose(POSITION, ROTATION, SCALE)
}

// 0 at the middle of the grid, 1 at its corners.
function centreDistance(surface, row, col) {
  const dx = (col + 0.5) / surface.cols - 0.5
  const dy = (row + 0.5) / surface.rows - 0.5
  return Math.min(1, Math.hypot(dx, dy) * 2)
}

// The dome never reaches zero. At the corners (1 - d) is exactly 0, and a heap of zero
// height is an invisible piece with a degenerate collider -- something you can neither see
// nor drive over nor clear. The edge of a pile still has debris on it; there is just not
// much of it.
function dome(surface, row, col, falloff, edge) {
  return edge + (1 - edge) * Math.pow(1 - centreDistance(surface, row, col), falloff)
}

// The mean of the dome across the heaps this surface actually holds, so dividing by it
// leaves the average depth exactly where Ruby put it. Memoised per surface: it walks the
// whole grid, and the same answer is wanted once per heap.
const MEANS = new WeakMap()

function domeMean(surface, falloff, edge) {
  let cached = MEANS.get(surface)
  if (cached && cached.falloff === falloff && cached.edge === edge) return cached.mean

  let total = 0
  let count = 0
  for (let row = 0; row < surface.rows; row += 1) {
    for (let col = 0; col < surface.cols; col += 1) {
      if (materialAt(surface, row, col) === "void") continue

      total += dome(surface, row, col, falloff, edge)
      count += 1
    }
  }

  const mean = count > 0 && total > 0 ? total / count : 1
  MEANS.set(surface, { falloff, edge, mean })
  return mean
}

// The heaps outward from the middle, which is the order they are revealed in -- and which
// MUST match Building::Rubble.pile_indices, because the server gates damage on the revealed
// prefix. Quantised and index-tied for the same reason it is in Ruby: two languages
// agreeing on a float comparison is not something to rest a shared order on.
export function pileOrder(surface) {
  let cached = ORDERS.get(surface)
  if (cached) return cached

  const piles = []
  for (let row = 0; row < surface.rows; row += 1) {
    for (let col = 0; col < surface.cols; col += 1) {
      if (materialAt(surface, row, col) === "void") continue

      const dx = (col + 0.5) / surface.cols - 0.5
      const dy = (row + 0.5) / surface.rows - 0.5
      piles.push([ Math.round(Math.hypot(dx, dy) * 1000000), surface.off + row * surface.cols + col ])
    }
  }

  piles.sort((a, b) => a[0] - b[0] || a[1] - b[1])
  cached = piles.map((pile) => pile[1])
  ORDERS.set(surface, cached)
  return cached
}

const ORDERS = new WeakMap()

// How many different lumps exist, when Ruby has not said. The real number ships in
// rules.collapse.rubble.shapes -- it decides how many instanced pools are allocated, so
// the two sides cannot be allowed to disagree about it.
export const SHAPES = 16

export function shapeFor(surface, row, col, shapes = SHAPES) {
  return Math.floor(((noise(surface, row, col, 53) + 1) / 2) * shapes) % shapes
}

// A lump of debris, not a box.
//
// An icosahedron with every vertex shoved about and then squashed flat: the faces come out
// irregular, the silhouette is angular rather than square, and the four of them look like
// four different heaps rather than one heap rotated. Vertices are displaced by a hash of
// their own position and the variant, so a given variant is the same lump on every client
// and in every session -- these are geometry, not decoration, and a heap you drive around
// has to be the heap everybody else drives around.
export function lumpGeometry(variant) {
  // Alternating the base solid as well as the wobble. Sixteen wobbles of one icosahedron
  // are sixteen versions of the same silhouette; a dodecahedron and a subdivided
  // icosahedron bring genuinely different face counts and profiles, and the eye reads that
  // long before it reads a displaced vertex.
  const geometry = baseSolid(variant)
  const position = geometry.attributes.position

  // WHICH AXIS IS UP: the cell matrix is built with makeBasis(u, v, n), so a lump's local
  // x and y are the two HORIZONTAL axes of the surface and its local z is the normal --
  // straight up. Squashing y flattens a heap sideways and leaves it free to grow upward,
  // which is how these came out as vertical spikes rather than as heaps.
  //
  for (let i = 0; i < position.count; i += 1) {
    const x = position.getX(i)
    const y = position.getY(i)
    const z = position.getZ(i)
    const wobble = 1 + hash(x, y, z, variant) * 0.6

    position.setXYZ(
      i,
      x * wobble,
      y * wobble,
      // Up. Squashed, because a heap settles, and squashed LAST so the wobble cannot undo
      // it and put a spike back.
      z * wobble * 0.5
    )
  }

  // NORMALISED TO FILL ITS BOX, and this is the difference between a volume model that is
  // right on paper and rubble that is right on screen. A lump is scaled by a box whose
  // height is the depth Ruby computed from the building's own material -- so a lump filling
  // 42% of that box drew 42% of the debris, and left the other 58% as collider standing
  // invisibly above the rubble. Now the box's extents ARE the lump's extents: what the
  // model says is what you see and what you hit.
  //
  // Proportion variety moves to the instance (see the aspect in rubbleMatrix), because
  // normalising every axis is exactly what throws it away here.
  const box = new THREE.Box3().setFromBufferAttribute(position)
  const size = box.getSize(new THREE.Vector3())
  const centre = box.getCenter(new THREE.Vector3())

  for (let i = 0; i < position.count; i += 1) {
    position.setXYZ(
      i,
      size.x > 1e-6 ? (position.getX(i) - centre.x) / size.x : 0,
      size.y > 1e-6 ? (position.getY(i) - centre.y) / size.y : 0,
      size.z > 1e-6 ? (position.getZ(i) - centre.z) / size.z : 0
    )
  }

  position.needsUpdate = true
  geometry.computeVertexNormals()
  return geometry
}

function baseSolid(variant) {
  switch (variant % 3) {
    case 0: return new THREE.IcosahedronGeometry(0.5, 0)
    case 1: return new THREE.DodecahedronGeometry(0.5, 0)
    default: return new THREE.IcosahedronGeometry(0.5, 1)
  }
}

// Deterministic in the vertex's own position, so the same variant is the same lump
// everywhere. Quantised first, because a float comparison across machines is not a thing
// to rely on.
function hash(a, b, c, salt) {
  let h = (Math.round(a * 1000) + 1) * 73856093
  h ^= (Math.round(b * 1000) + 1) * 19349663
  h ^= (Math.round(c * 1000) + 1) * 83492791
  h ^= (salt + 1) * 2971215073
  return ((Math.abs(h) % 10000) / 10000) * 2 - 1
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
