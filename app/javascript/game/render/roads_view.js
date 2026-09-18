import * as THREE from "three"

// Every road in the world as ONE mesh. A polyline becomes a ribbon half its width either
// side of the centreline with mitred joins, subdivided so no edge is longer than STEP,
// every vertex laid on the ground it crosses plus `rules.lift`. No colliders: the car
// drives on the heightfield, which the terrain model already shapes to the road.
const STEP = 5

export function buildRoadsView(scene, roads, ground, rules = {}) {
  if (!roads || roads.length === 0) return null

  const lift = rules.lift ?? 0.03
  const colours = rules.colours ?? {}
  const positions = []
  const colors = []
  const indices = []
  const colour = new THREE.Color()
  const height = ground || (() => 0)

  for (const road of roads) {
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
      }
      if (i > 0) {
        const a = base + (i - 1) * 2
        indices.push(a, a + 1, a + 2, a + 1, a + 3, a + 2)
      }
    }
  }

  const geometry = new THREE.BufferGeometry()
  geometry.setAttribute("position", new THREE.Float32BufferAttribute(positions, 3))
  geometry.setAttribute("color", new THREE.Float32BufferAttribute(colors, 3))
  geometry.setIndex(indices)
  geometry.computeVertexNormals()
  const mesh = new THREE.Mesh(geometry, new THREE.MeshStandardMaterial({
    vertexColors: true, roughness: 0.95, metalness: 0.02,
    // Drawn a hair in front of the terrain it lies on, whatever the depth buffer thinks.
    polygonOffset: true, polygonOffsetFactor: -1, polygonOffsetUnits: -1
  }))
  mesh.name = "roads"
  mesh.receiveShadow = true
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
