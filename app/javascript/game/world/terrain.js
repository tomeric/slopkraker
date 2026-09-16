// The ground as a heightfield: loaded from the tile endpoint, sampled, and turned into
// the buffers the physics and the renderer stand on.
//
// One Float32Array of metres per tile serves all three -- the Rapier heightfield, the
// render mesh and heightAt -- so they agree on every sample to the bit. What can still
// disagree is the TRIANGULATION of each cell, and that is the whole hazard here:
// Rapier's heightfield splits every cell on the anti-diagonal (shared edge from the
// south-west corner to the north-east one; measured against the vendored build, not read
// off the docs), so the index buffer below does the same, heightAt picks the same triangle
// by the same `fu + fv <= 1` rule, and __arenaTerrainProbe proves all three agree at
// runtime. PlaneGeometry splits its cells the other way and is never used for terrain.
//
// Rows run north to south (with z), columns west to east (with x), row-major in the blob
// and in every buffer here except the one handed to Rapier, which wants column-major.
export class Terrain {
  constructor(manifest, tiles) {
    this.tileSize = manifest.tile_size
    this.step = manifest.height_step
    this.n = manifest.height_n
    // Outside every tile the sampler answers this, as Ruby's does.
    this.fallback = 0
    this.list = tiles
    this.tiles = new Map()
    for (const tile of tiles) this.tiles.set(key(tile.tx, tile.tz), tile)
    this.min = Math.min(...tiles.map((tile) => tile.min))
    this.max = Math.max(...tiles.map((tile) => tile.max))
  }

  tileAt(x, z) {
    return this.tiles.get(key(Math.floor(x / this.tileSize), Math.floor(z / this.tileSize)))
  }

  // Which cell of a tile a point is in and where inside it, as Tile#height_at works it out.
  cellOf(tile, x, z) {
    const u = (x - tile.originX) / this.step
    const v = (z - tile.originZ) / this.step
    const col = clamp(Math.floor(u), 0, this.n - 2)
    const row = clamp(Math.floor(v), 0, this.n - 2)
    return { row, col, fu: u - col, fv: v - row }
  }

  // Port of Game::Terrain::Sampler#height_at -> Tile#height_at -> Tile.interpolate. The
  // TRIANGLE, never the bilinear average: bilinear is off by up to eighty centimetres
  // where terrain steps across a cell, which is how props end up floating.
  heightAt(x, z) {
    const tile = this.tileAt(x, z)
    if (!tile) return this.fallback

    const { row, col, fu, fv } = this.cellOf(tile, x, z)
    const n = this.n
    const h = tile.heights
    return interpolate(
      h[row * n + col], h[row * n + col + 1], h[(row + 1) * n + col], h[(row + 1) * n + col + 1], fu, fv
    )
  }

  // What the OTHER diagonal would say here. Exists for the probe test, which has to show it
  // would have noticed the wrong split: a survey where this never differs from the drawn
  // height would pass whatever Rapier did.
  otherDiagonalAt(x, z) {
    const tile = this.tileAt(x, z)
    if (!tile) return null

    const { row, col, fu, fv } = this.cellOf(tile, x, z)
    const n = this.n
    const h = tile.heights
    return otherDiagonal(
      h[row * n + col], h[row * n + col + 1], h[(row + 1) * n + col], h[(row + 1) * n + col + 1], fu, fv
    )
  }
}

// Game::Terrain::Tile.interpolate, verbatim. h00 is the cell's north-west sample, h10 the
// one to its east, h01 the one to its south, h11 the south-east.
export function interpolate(h00, h10, h01, h11, fu, fv) {
  if (fu + fv <= 1) return h00 + (h10 - h00) * fu + (h01 - h00) * fv
  return h11 + (h01 - h11) * (1 - fu) + (h10 - h11) * (1 - fv)
}

// The main-diagonal split -- shared edge from north-west to south-east -- which is what
// PlaneGeometry would have drawn and what nothing here uses.
export function otherDiagonal(h00, h10, h01, h11, fu, fv) {
  if (fv >= fu) return h00 + (h11 - h01) * fu + (h01 - h00) * fv
  return h00 + (h10 - h00) * fu + (h11 - h10) * fv
}

// Fetch every tile in the manifest and decode it. Null manifest, null terrain: a flat
// world boots exactly as it did before terrain existed. A tile that fails to arrive
// throws, naming itself, so the page says so rather than dropping the car through the
// place the ground should have been.
export async function loadTerrain(manifest) {
  if (!manifest) return null

  const tiles = await Promise.all(manifest.tiles.map((entry) => loadTile(manifest, entry)))
  return new Terrain(manifest, tiles)
}

async function loadTile(manifest, entry) {
  const response = await fetch(entry.url)
  if (!response.ok) throw new Error(`terrain tile (${entry.tx}, ${entry.tz}) returned ${response.status}`)

  // Signed 16-bit centimetres, little-endian, offset by the tile's base: one Int16Array
  // construction, as the codec's comment promised. Every machine this runs on is
  // little-endian, which is the assumption the typed array makes.
  const raw = new Int16Array(await response.arrayBuffer())
  const n = manifest.height_n
  if (raw.length !== n * n) {
    throw new Error(`terrain tile (${entry.tx}, ${entry.tz}) holds ${raw.length} samples, expected ${n * n}`)
  }

  const heights = new Float32Array(raw.length)
  for (let k = 0; k < raw.length; k += 1) heights[k] = (raw[k] + entry.base_cm) / 100

  return {
    tx: entry.tx, tz: entry.tz,
    originX: entry.tx * manifest.tile_size, originZ: entry.tz * manifest.tile_size,
    heights, min: entry.min_cm / 100, max: entry.max_cm / 100,
    // Set by the terrain view once the mesh exists, so the probe can read the drawn
    // triangles back.
    mesh: null
  }
}

// The row/column-to-world mapping, in one place. Vertex (i, j) of a tile sits at the
// tile's origin plus j steps east and i steps south, at the height of sample i * n + j.
export function terrainVertex(terrain, tile, i, j, out) {
  return out.set(
    tile.originX + j * terrain.step,
    tile.heights[i * terrain.n + j],
    tile.originZ + i * terrain.step
  )
}

// Two triangles per cell, split on the ANTI-diagonal to match Rapier, wound so their
// normals point up. With a = (i, j) north-west, b = (i+1, j) south-west, c = (i, j+1)
// north-east and d = (i+1, j+1) south-east: (a, b, c) is the triangle where fu + fv <= 1
// and (b, d, c) is the other. Never PlaneGeometry: it splits the other way.
export function terrainIndexBuffer(n) {
  const cells = n - 1
  const index = new Uint32Array(cells * cells * 6)
  let k = 0
  for (let i = 0; i < cells; i += 1) {
    for (let j = 0; j < cells; j += 1) {
      const a = i * n + j
      const b = (i + 1) * n + j
      const c = i * n + j + 1
      const d = (i + 1) * n + j + 1
      index[k++] = a; index[k++] = b; index[k++] = c
      index[k++] = b; index[k++] = d; index[k++] = c
    }
  }
  return index
}

// Rapier wants the heights matrix column-major -- sample (i, j) at i + j * n -- with row i
// along its local z and column j along its local x. Ours is row-major, so this is the
// transpose, and it is the only place the two layouts meet.
export function physicsHeights(tile, n) {
  const out = new Float32Array(n * n)
  for (let i = 0; i < n; i += 1) {
    for (let j = 0; j < n; j += 1) out[i + j * n] = tile.heights[i * n + j]
  }
  return out
}

// The height of the DRAWN ground under a point: barycentric interpolation over the render
// mesh's own triangles, read from the buffers three.js draws from. Independent of the
// formula that built those buffers on purpose -- this is the half of the probe that would
// notice if the index buffer said something different from heightAt.
export function renderHeightAt(terrain, x, z) {
  const tile = terrain.tileAt(x, z)
  const geometry = tile?.mesh?.geometry
  if (!geometry) return null

  const { row, col } = terrain.cellOf(tile, x, z)
  const index = geometry.index.array
  const position = geometry.attributes.position.array
  const first = (row * (terrain.n - 1) + col) * 6

  for (let t = 0; t < 2; t += 1) {
    const a = index[first + t * 3]
    const b = index[first + t * 3 + 1]
    const c = index[first + t * 3 + 2]
    const bary = barycentric(x, z, position, a, b, c)
    if (bary) return bary.u * position[a * 3 + 1] + bary.v * position[b * 3 + 1] + bary.w * position[c * 3 + 1]
  }
  return null
}

// Barycentric coordinates of (x, z) in the triangle a, b, c of the position buffer, seen
// from above, or null when the point is outside it. A point on the shared edge is inside
// both triangles and gets the same height from either.
function barycentric(x, z, p, a, b, c) {
  const ax = p[a * 3], az = p[a * 3 + 2]
  const bx = p[b * 3], bz = p[b * 3 + 2]
  const cx = p[c * 3], cz = p[c * 3 + 2]
  const det = (bx - ax) * (cz - az) - (cx - ax) * (bz - az)
  if (Math.abs(det) < 1e-12) return null

  const v = ((x - ax) * (cz - az) - (cx - ax) * (z - az)) / det
  const w = ((bx - ax) * (z - az) - (x - ax) * (bz - az)) / det
  const u = 1 - v - w
  const eps = -1e-9
  if (u < eps || v < eps || w < eps) return null
  return { u, v, w }
}

function key(tx, tz) {
  return `${tx},${tz}`
}

function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max)
}
