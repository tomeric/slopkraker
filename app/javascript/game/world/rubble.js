import * as THREE from "three"
import { cellMatrix, materialAt } from "game/world/surface"

// Where one heap of wreckage sits, how big it is, and what sits in it.
//
// A heap is ONE piece: one index, one collider, one entry in the state arrays. It is DRAWN
// as a lump of dust and mortar with chunks of the building's own materials in and on it,
// and everything about that picture -- where the lump sits, how tall it is, which chunk is
// brick and which is timber, where each one lies and how it leans -- comes from the cell's
// own coordinates and the surface's seed, and NEVER from Math.random. That is the whole
// reason two players see the same wreckage without a byte of it going over the wire: the
// server decided which cells hold a heap when it generated the surface, shipped what the
// building was made of, and both clients work the rest out from numbers they already hold.

// Where one heap sits and how big it is, in WORLD space.
//
// The rubble grid always lies flat on the ground -- u east, v south, and a normal that
// points DOWN, which is what made every earlier attempt to lift or flatten a heap along
// the surface's own axes come out inverted. So a heap is placed in world terms from the
// start: a centre on the ground, a yaw about world up, two horizontal half-extents and a
// height. Nothing here reads the surface normal.
//
// `grow` is how far risen the heap is, 0..1. A heap arrives by growing out of the ground
// rather than popping into it, and everything about it -- the lump's height, the chunks'
// size and where they sit -- is derived from this one frame, so the two cannot come apart.
export function heapFrame(surface, row, col, origin, rules = {}, grow = 1, out = FRAME) {
  const jitter = rules.jitter ?? 0.55
  const scale = rules.scale ?? 0.85
  const falloff = rules.falloff ?? 2.5
  const edge = rules.edge ?? 0.06
  const spread = rules.spread ?? 0.55
  const sink = rules.sink ?? [ 0.05, 0.45 ]

  cellMatrix(surface, row, col, MATRIX, origin)
  MATRIX.decompose(POSITION, ROTATION, SCALE)

  // Along the surface's own axes, so a nudge stays in the plane the heaps lie on. Pushed
  // well off the grid and INTO each other: rubble that interpenetrates reads as one pile,
  // where rubble that keeps to its own square reads as forty objects.
  U.set(1, 0, 0).applyQuaternion(ROTATION)
  V.set(0, 1, 0).applyQuaternion(ROTATION)
  POSITION
    .addScaledVector(U, noise(surface, row, col, 11) * jitter * SCALE.x)
    .addScaledVector(V, noise(surface, row, col, 17) * jitter * SCALE.y)

  // Rubble piles toward the middle of what fell. A dome, and a VOLUME CONSERVING one: the
  // profile is divided by its own mean over the heaps, so the material Ruby computed is
  // neither created nor destroyed -- it is simply put where a pile puts it instead of
  // being spread flat. That is the whole difference between a pile of debris and a bumpy
  // area, and it is free.
  const vary = 1 + noise(surface, row, col, 31) * spread
  const heap = vary * dome(surface, row, col, falloff, edge) / domeMean(surface, falloff, edge)
  // Plan proportion, per heap rather than per shape, and area preserving -- so some lumps
  // are long and narrow and others nearly square without any of them covering more ground
  // than the coverage model counted on.
  const aspect = 1 + noise(surface, row, col, 61) * (rules.aspect ?? 0.15)
  // How far the lump settles into the ground it landed on. Bounded well short of burying
  // it: a third has to stand proud or it stops being something you have to get around.
  const buried = sink[0] + ((noise(surface, row, col, 59) + 1) / 2) * (sink[1] - sink[0])
  const height = Math.max(SCALE.z * heap * grow, MIN_HEIGHT)

  // Cells are centred on their surface plane, and Ruby lifted the plane by half the depth
  // so a heap would sit ON the ground: the ground is therefore half a thickness below.
  out.ground = POSITION.y - Math.abs(surface.t) / 2
  out.x = POSITION.x
  out.z = POSITION.z
  out.y = out.ground + height / 2 - height * buried
  out.yaw = noise(surface, row, col, 23) * Math.PI
  out.a = SCALE.x * scale * vary * aspect / 2
  out.b = SCALE.y * scale * vary / aspect / 2
  out.height = height
  out.top = out.ground + height * (1 - buried)
  // How this heap compares with the average heap on the site: one at the mean, small at
  // the rim. The chunks shrink with it.
  out.relative = heap
  out.grow = grow
  return out
}

// The lump's transform: the frame as a box, spun about world up and NOT leaned. The
// collider is sized from this, and a car driving over forty leaned boxes is a car driving
// over forty invisible ramps; the lean lives on the chunks, where it reads as dropped
// rather than laid. Local z is world up -- lumpGeometry is squashed along z -- so the
// rotation carries local z onto world y before the yaw is applied.
export function heapMatrix(surface, row, col, target, origin, rules = {}, grow = 1) {
  const frame = heapFrame(surface, row, col, origin, rules, grow)

  ROTATION.setFromAxisAngle(WORLD_UP, frame.yaw).multiply(Z_UP)
  return target.compose(
    POSITION.set(frame.x, frame.y, frame.z),
    ROTATION,
    SCALE.set(frame.a * 2, frame.b * 2, frame.height)
  )
}

// The chunks of the building's own material that sit in and on a heap.
//
// A heap has ONE piece index and ONE collider; these are only how it is drawn. Each chunk
// is an instance in a per-material pool -- `brick#rubble`, `timber#rubble` -- placed by a
// hash of the cell and its own ordinal, so every client puts the same plank in the same
// place. The material is drawn from the building's own mix, which Ruby computed from what
// the building was made of, so a brick house leaves brick and a concrete one leaves slabs.
//
// `visit` receives the chunk's ordinal, its material name and a matrix it must not keep.
export function heapFragments(surface, row, col, frame, mix, materials, rules = {}, visit) {
  const count = rules.fragments ?? 0
  const tilt = rules.tilt ?? 0.28
  if (!mix || mix.length === 0 || count <= 0) return

  // Rim heaps carry smaller chunks and centre heaps larger ones, rather than fewer and
  // more: the count is fixed because the pools are sized up front. Scattered small chunks
  // are what the edge of a pile looks like, and the whole wall sections that survive a
  // fall are buried in the middle of it. While the heap is still rising its chunks are
  // rising with it.
  const size = (0.55 + 0.45 * Math.min(1.6, frame.relative)) * (0.5 + 0.5 * frame.grow)
  const cosYaw = Math.cos(frame.yaw)
  const sinYaw = Math.sin(frame.yaw)

  for (let k = 0; k < count; k += 1) {
    const name = fragmentMaterial(surface, row, col, k, mix)
    const chunk = materials[name]?.chunk || DEFAULT_CHUNK

    // Spread through the heap's ellipse, denser toward the middle -- the square root is
    // what makes a uniform draw uniform over AREA rather than bunched at the centre.
    const radius = Math.sqrt((fnoise(surface, row, col, k, 0) + 1) / 2)
    const angle = fnoise(surface, row, col, k, 1) * Math.PI
    const lx = Math.cos(angle) * radius * frame.a * 0.92
    const lz = Math.sin(angle) * radius * frame.b * 0.92

    const sx = chunk.size[0] * (1 + chunk.vary * fnoise(surface, row, col, k, 2)) * size
    const sy = chunk.size[1] * (1 + chunk.vary * fnoise(surface, row, col, k, 3)) * size
    const sz = chunk.size[2] * (1 + chunk.vary * fnoise(surface, row, col, k, 4)) * size

    // Sitting IN the top of the lump, some further in than others, and never below the
    // ground: the lump's crest falls away from its middle roughly as a dome does.
    const crest = frame.ground + (frame.top - frame.ground) * Math.sqrt(Math.max(0, 1 - radius * radius))
    const embed = 0.15 + 0.4 * ((fnoise(surface, row, col, k, 5) + 1) / 2)
    const y = Math.max(crest - sy * embed, frame.ground + sy * 0.35)

    // Its own yaw, then leaned off level about a horizontal axis. Local y stays roughly
    // up, which is what keeps a plank lying flat and a tile lying flat.
    ROTATION.setFromAxisAngle(WORLD_UP, fnoise(surface, row, col, k, 6) * Math.PI)
    const lean = fnoise(surface, row, col, k, 7) * Math.PI
    LEAN_AXIS.set(Math.cos(lean), 0, Math.sin(lean))
    SPIN.setFromAxisAngle(LEAN_AXIS, fnoise(surface, row, col, k, 9) * tilt)
    ROTATION.premultiply(SPIN)

    POSITION.set(
      frame.x + lx * cosYaw + lz * sinYaw,
      y,
      frame.z - lx * sinYaw + lz * cosYaw
    )
    visit(k, name, FRAGMENT.compose(POSITION, ROTATION, SCALE.set(sx, sy, sz)))
  }
}

// Which material chunk `k` of a heap is made of. A seeded draw against the cumulative
// mix, largest share first. Exported on its own because the pools are counted before any
// heap is built, and the count has to run exactly this draw.
export function fragmentMaterial(surface, row, col, k, mix) {
  const draw = (fnoise(surface, row, col, k, 8) + 1) / 2
  let reached = 0

  for (const [ name, share ] of mix) {
    reached += share
    if (draw < reached) return name
  }
  return mix[mix.length - 1][0]
}

export const FRAGMENT_SUFFIX = "#rubble"

// The pool a material's chunks are drawn from. The suffix chooses a SHAPE and never a
// material, exactly as `rubble#3` does: colour, opacity and everything else stay the
// material's.
export function fragmentPool(name) {
  return `${name}${FRAGMENT_SUFFIX}`
}

export function isFragmentPool(pool) {
  return pool.endsWith(FRAGMENT_SUFFIX)
}

// A chunk of something, not a box.
//
// A unit cube whose eight corners have each been shoved by a hash of their own position,
// then normalised to fill the unit box again so the instance scale is the chunk's real
// size. Non-indexed, so the lighting is faceted -- a chunk of masonry has faces. How far
// off a box it is comes from the material: a plank is nearly one, a shard of glass is not.
export function chunkGeometry(chunk = DEFAULT_CHUNK) {
  const jitter = (chunk.jitter ?? 0.3) * 0.5
  const corners = []
  for (let i = 0; i < 8; i += 1) {
    const x = i & 1 ? 0.5 : -0.5
    const y = i & 2 ? 0.5 : -0.5
    const z = i & 4 ? 0.5 : -0.5
    corners.push([
      x + hash(x, y, z, 1) * jitter,
      y + hash(x, y, z, 2) * jitter,
      z + hash(x, y, z, 3) * jitter
    ])
  }

  // Each face as a quad wound counter-clockwise seen from outside, split on a diagonal.
  // The corners are no longer coplanar, which is exactly the point.
  const quads = [
    [ 1, 3, 7, 5 ], [ 0, 4, 6, 2 ],
    [ 2, 6, 7, 3 ], [ 0, 1, 5, 4 ],
    [ 4, 5, 7, 6 ], [ 0, 2, 3, 1 ]
  ]
  const positions = []
  for (const [ a, b, c, d ] of quads) {
    positions.push(...corners[a], ...corners[b], ...corners[c])
    positions.push(...corners[a], ...corners[c], ...corners[d])
  }

  const geometry = new THREE.BufferGeometry()
  geometry.setAttribute("position", new THREE.Float32BufferAttribute(positions, 3))

  const position = geometry.attributes.position
  const box = new THREE.Box3().setFromBufferAttribute(position)
  const size = box.getSize(new THREE.Vector3())
  const centre = box.getCenter(new THREE.Vector3())
  for (let i = 0; i < position.count; i += 1) {
    position.setXYZ(
      i,
      (position.getX(i) - centre.x) / size.x,
      (position.getY(i) - centre.y) / size.y,
      (position.getZ(i) - centre.z) / size.z
    )
  }
  position.needsUpdate = true
  geometry.computeVertexNormals()
  return geometry
}

// What a chunk looks like when the material table has not said: a brick-sized block.
const DEFAULT_CHUNK = { size: [ 0.5, 0.3, 0.3 ], vary: 0.4, jitter: 0.3 }

// 0 at the middle of the grid, 1 at its corners.
function centreDistance(surface, row, col) {
  const dx = (col + 0.5) / surface.cols - 0.5
  const dy = (row + 0.5) / surface.rows - 0.5
  return Math.min(1, Math.hypot(dx, dy) * 2)
}

// A bell, not a cone. The profile used to be (1 - d) to a power, which is very nearly a
// straight line from the peak to the rim, and the silhouette of the pile was a triangle
// with dead straight sides. A cosine bell is rounded on top and concave at the foot, which
// is the shape a pile of anything loose actually takes; `falloff` raises it to a power to
// set how steep the shoulders are.
//
// The dome never reaches zero. At the rim the bell is exactly 0, and a heap of zero height
// is an invisible piece with a degenerate collider -- something you can neither see nor
// drive over nor clear. The edge of a pile still has debris on it; there is just not much.
function dome(surface, row, col, falloff, edge) {
  const bell = (1 + Math.cos(Math.PI * centreDistance(surface, row, col))) / 2
  return edge + (1 - edge) * Math.pow(bell, falloff)
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
export const SHAPES = 12

export function shapeFor(surface, row, col, shapes = SHAPES) {
  return Math.floor(((noise(surface, row, col, 53) + 1) / 2) * shapes) % shapes
}

// A lump of dust and mortar, not a box.
//
// An icosahedron with every vertex shoved about and then squashed flat: the faces come out
// irregular, the silhouette is angular rather than square, and the twelve of them look like
// twelve different heaps rather than one heap rotated. Vertices are displaced by a hash of
// their own position and the variant, so a given variant is the same lump on every client
// and in every session -- these are geometry, not decoration, and a heap you drive around
// has to be the heap everybody else drives around.
export function lumpGeometry(variant) {
  // Alternating the base solid as well as the wobble. Twelve wobbles of one icosahedron
  // are twelve versions of the same silhouette; a dodecahedron and a subdivided
  // icosahedron bring genuinely different face counts and profiles, and the eye reads that
  // long before it reads a displaced vertex.
  const geometry = baseSolid(variant)
  const position = geometry.attributes.position

  // WHICH AXIS IS UP: a lump's local z is world up -- heapMatrix rotates it there -- so
  // squashing z is what flattens a heap. Squashing y flattened it sideways and left it
  // free to grow upward, which is how these once came out as vertical spikes.
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

// -1..1, deterministic in the surface's seed and offset, the cell, the chunk's ordinal and
// which of its numbers is wanted. A stronger mix than `noise`, because a chunk's several
// numbers are drawn from consecutive salts and the weak hash lines them up. Math.imul is
// exact 32-bit arithmetic in every engine, which is what makes this the same number on
// every client.
function fnoise(surface, row, col, k, j) {
  let h = Math.imul(((surface.seed ?? 0) + 0x9e3779b9) | 0, 0x85ebca6b)
  h = Math.imul(h ^ (surface.off + 1), 0xc2b2ae35)
  h = Math.imul(h ^ (row * 8191 + col + 1), 0x27d4eb2f)
  h = Math.imul(h ^ (k * 131 + j + 1), 0x165667b1)
  h ^= h >>> 15
  h = Math.imul(h, 0x2c1b3c6d)
  h ^= h >>> 12
  h = Math.imul(h, 0x297a2d39)
  h ^= h >>> 15
  return ((h >>> 0) / 4294967296) * 2 - 1
}

const MIN_HEIGHT = 0.01
const WORLD_UP = new THREE.Vector3(0, 1, 0)
// Rotates local +z onto world +y.
const Z_UP = new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(1, 0, 0), -Math.PI / 2)
const FRAME = {}
const MATRIX = new THREE.Matrix4()
const FRAGMENT = new THREE.Matrix4()
const POSITION = new THREE.Vector3()
const ROTATION = new THREE.Quaternion()
const SCALE = new THREE.Vector3()
const SPIN = new THREE.Quaternion()
const U = new THREE.Vector3()
const V = new THREE.Vector3()
const LEAN_AXIS = new THREE.Vector3()
