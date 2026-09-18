import * as THREE from "three"
import { TILE } from "game/render/looks"

// Every road in the world, and every lawn, as ONE mesh. A polyline becomes a ribbon half
// its width either side of the centreline with mitred joins, subdivided so no edge is
// longer than STEP, every vertex laid on the ground it crosses plus `rules.lift`. No
// colliders: the car drives on the heightfield, which the terrain model already shapes to
// the road.
//
// A lawn is a ring draped the same way, coloured grass and flagged `grass` so the one
// material can lay the lawn texture over it and leave the asphalt alone.
const STEP = 5
// Lawns are subdivided finer than roads: a garden is a few metres across and has to
// follow the ground it lies on rather than bridge it.
const LAWN_STEP = 2

export function buildRoadsView(scene, roads, ground, rules = {}, { lawns = [], gardens = {}, looks = null } = {}) {
  if ((!roads || roads.length === 0) && lawns.length === 0) return null

  const lift = rules.lift ?? 0.03
  const colours = rules.colours ?? {}
  const positions = []
  const colors = []
  const grass = []
  const indices = []
  const colour = new THREE.Color()
  const height = ground || (() => 0)

  for (const road of roads || []) {
    // Before densify, not after: a road with no points at all makes `densify` push
    // `undefined` as its last vertex, and `normalAt` then reads [0] off it and takes the
    // whole ribbon -- every road in the world -- down with it.
    if (!road.points || road.points.length < 2) continue
    const points = densify(road.points, STEP)
    if (points.length < 2) continue
    colour.set(colours[road.kind] ?? "#2e3236")
    const half = (road.width ?? 5.5) / 2
    const base = positions.length / 3

    for (let i = 0; i < points.length; i += 1) {
      const [ nx, nz ] = normalAt(points, i)
      for (const side of [ -1, 1 ]) {
        const x = points[i][0] + side * nx * half
        const z = points[i][1] + side * nz * half
        positions.push(x, height(x, z) + lift, z)
        colors.push(colour.r, colour.g, colour.b)
        grass.push(0)
      }
      if (i > 0) {
        const a = base + (i - 1) * 2
        indices.push(a, a + 1, a + 2, a + 1, a + 3, a + 2)
      }
    }
  }

  // Front gardens: a ring per lawn, subdivided and draped on the ground under the roads'
  // own lift, coloured grass and flagged so the shader below lays the lawn texture only
  // where this flag is set.
  const lawnLift = gardens.lift ?? 0.02
  const grassColour = new THREE.Color(gardens.grass ?? "#4f7a36")
  const jitter = gardens.jitter ?? 0
  let lawnVertices = 0
  for (const ring of lawns) {
    if (!ring || ring.length !== 4) continue
    const [ a, b, c, d ] = ring
    const n = Math.max(1, Math.ceil(Math.hypot(b[0] - a[0], b[1] - a[1]) / LAWN_STEP))
    const m = Math.max(1, Math.ceil(Math.hypot(d[0] - a[0], d[1] - a[1]) / LAWN_STEP))
    const base = positions.length / 3
    for (let j = 0; j <= m; j += 1) {
      for (let i = 0; i <= n; i += 1) {
        const s = i / n
        const t = j / m
        // Bilinear over the ring: a -> b along the first edge, a -> d along the last.
        const x = (1 - t) * ((1 - s) * a[0] + s * b[0]) + t * ((1 - s) * d[0] + s * c[0])
        const z = (1 - t) * ((1 - s) * a[1] + s * b[1]) + t * ((1 - s) * d[1] + s * c[1])
        positions.push(x, height(x, z) + lawnLift, z)
        const shade = 1 + (hash(x, z) - 0.5) * jitter
        colors.push(grassColour.r * shade, grassColour.g * shade, grassColour.b * shade)
        grass.push(1)
        lawnVertices += 1
        if (i > 0 && j > 0) {
          const v = base + j * (n + 1) + i
          indices.push(v - n - 2, v - 1, v - n - 1, v - 1, v, v - n - 1)
        }
      }
    }
  }

  const geometry = new THREE.BufferGeometry()
  geometry.setAttribute("position", new THREE.Float32BufferAttribute(positions, 3))
  geometry.setAttribute("color", new THREE.Float32BufferAttribute(colors, 3))
  geometry.setAttribute("grass", new THREE.Float32BufferAttribute(grass, 1))
  geometry.setIndex(indices)
  geometry.computeVertexNormals()
  const material = new THREE.MeshStandardMaterial({
    vertexColors: true, roughness: 0.95, metalness: 0.02,
    // Drawn a hair in front of the terrain it lies on, whatever the depth buffer thinks.
    polygonOffset: true, polygonOffsetFactor: -1, polygonOffsetUnits: -1
  })
  const lawn = looks?.lawn(gardens.look)
  if (lawn) {
    // One material, two surfaces: the lawn texture is laid in world metres and mixed in
    // by the `grass` flag, so the asphalt stays flat and the lawn reads as grass. `low`
    // quality never reaches here -- Looks#lawn answers null with textures off -- so a
    // lawn at `low` is the flat vertex colour above and nothing else.
    material.map = lawn
    material.onBeforeCompile = (shader) => {
      shader.vertexShader = `attribute float grass;\nvarying float vGrass;\n#define TILE_METRES ${TILE.toFixed(1)}\n` +
        shader.vertexShader.replace("#include <uv_vertex>", `
#if defined( USE_UV ) || defined( USE_ANISOTROPY )
  vUv = uv;
#endif
#ifdef USE_MAP
  vMapUv = ( modelMatrix * vec4( position, 1.0 ) ).xz / TILE_METRES;
#endif
vGrass = grass;
`)
      shader.fragmentShader = "varying float vGrass;\n" +
        shader.fragmentShader.replace("#include <map_fragment>", `
#ifdef USE_MAP
  vec4 lawnTexel = texture2D( map, vMapUv );
  diffuseColor *= mix( vec4( 1.0 ), lawnTexel, vGrass );
#endif
`)
    }
    material.customProgramCacheKey = () => "roads-lawn"
  }
  const mesh = new THREE.Mesh(geometry, material)
  mesh.name = "roads"
  mesh.receiveShadow = true
  mesh.userData.lawnVertices = lawnVertices
  scene.add(mesh)
  return mesh
}

// Points no more than `step` apart, so the ribbon follows the ground between the
// polyline's own vertices rather than bridging a dip.
function densify(points, step) {
  const out = []
  for (let i = 0; i < points.length - 1; i += 1) {
    const [ x0, z0 ] = points[i]
    const [ x1, z1 ] = points[i + 1]
    const n = Math.max(1, Math.ceil(Math.hypot(x1 - x0, z1 - z0) / step))
    for (let k = 0; k < n; k += 1) out.push([ x0 + (x1 - x0) * k / n, z0 + (z1 - z0) * k / n ])
  }
  out.push(points[points.length - 1])
  return out
}

// The unit normal at a vertex: perpendicular to the average of the directions into and
// out of it, which is what makes the join at a bend a mitre rather than a gap.
function normalAt(points, i) {
  const prev = points[Math.max(i - 1, 0)]
  const next = points[Math.min(i + 1, points.length - 1)]
  let dx = next[0] - prev[0]
  let dz = next[1] - prev[1]
  const length = Math.hypot(dx, dz) || 1
  dx /= length
  dz /= length
  return [ -dz, dx ]
}

// A seeded value in [0, 1) per point, so a lawn is not one flat green.
function hash(x, z) {
  let h = (Math.round(x * 10) * 374761393 + Math.round(z * 10) * 668265263) | 0
  h = Math.imul(h ^ (h >>> 13), 1274126177)
  return ((h ^ (h >>> 16)) >>> 0) / 4294967296
}
