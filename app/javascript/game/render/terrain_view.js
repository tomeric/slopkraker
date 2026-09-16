import * as THREE from "three"
import { terrainIndexBuffer, terrainVertex } from "game/world/terrain"

// The ground, drawn. One BufferGeometry per tile from the same Float32Array the collider
// stands on, indexed by hand (terrainIndexBuffer -- never PlaneGeometry, whose diagonal
// runs the other way), coloured per vertex by height and slope because the driver reads
// the relief mostly through those colours and the lighting.
//
// Normals come from the SAMPLER by central differences rather than from each tile's own
// triangles: a tile computing normals from only its own faces gets a different answer
// along its edge from the tile next door, and the seam shows as a line in the shading.
// heightAt crosses seams, so these do not.
export function buildTerrainView(scene, terrain, rules) {
  const group = new THREE.Group()
  group.name = "terrain"

  const low = new THREE.Color(rules.colours.low)
  const high = new THREE.Color(rules.colours.high)
  const steep = new THREE.Color(rules.colours.steep)
  const [ steepFrom, steepTo ] = rules.steep
  const range = Math.max(terrain.max - terrain.min, 1e-6)

  // vertexColors with an attribute that is ALWAYS bound -- the tinting trap is an unbound
  // one, which renders black. material.color stays white; the vertices carry the colour.
  const material = new THREE.MeshStandardMaterial({
    vertexColors: true, roughness: rules.roughness, metalness: 0.0
  })

  const n = terrain.n
  for (const tile of terrain.list) {
    const positions = new Float32Array(n * n * 3)
    const normals = new Float32Array(n * n * 3)
    const colours = new Float32Array(n * n * 3)

    for (let i = 0; i < n; i += 1) {
      for (let j = 0; j < n; j += 1) {
        const k = (i * n + j) * 3
        terrainVertex(terrain, tile, i, j, VERTEX)
        positions[k] = VERTEX.x
        positions[k + 1] = VERTEX.y
        positions[k + 2] = VERTEX.z

        slopeAt(terrain, VERTEX.x, VERTEX.z, SLOPE)
        NORMAL.set(-SLOPE.x, 1, -SLOPE.y).normalize()
        normals[k] = NORMAL.x
        normals[k + 1] = NORMAL.y
        normals[k + 2] = NORMAL.z

        COLOUR.copy(low).lerp(high, (VERTEX.y - terrain.min) / range)
        COLOUR.lerp(steep, smoothstep(Math.hypot(SLOPE.x, SLOPE.y), steepFrom, steepTo))
        colours[k] = COLOUR.r
        colours[k + 1] = COLOUR.g
        colours[k + 2] = COLOUR.b
      }
    }

    const geometry = new THREE.BufferGeometry()
    geometry.setAttribute("position", new THREE.BufferAttribute(positions, 3))
    geometry.setAttribute("normal", new THREE.BufferAttribute(normals, 3))
    geometry.setAttribute("color", new THREE.BufferAttribute(colours, 3))
    geometry.setIndex(new THREE.BufferAttribute(terrainIndexBuffer(n), 1))
    geometry.computeBoundingSphere()

    const mesh = new THREE.Mesh(geometry, material)
    mesh.name = `terrain:${tile.tx},${tile.tz}`
    mesh.receiveShadow = true
    mesh.castShadow = false
    tile.mesh = mesh
    group.add(mesh)
  }

  scene.add(group)
  return group
}

// dh/dx and dh/dz at a point, by central differences one step either side -- or one-sided
// at the world's rim, where the far side is off every tile and would read as the fallback.
// At a tile's edge the far side is the neighbouring tile, whose edge samples are shared,
// so the difference is continuous across the seam.
function slopeAt(terrain, x, z, out) {
  const step = terrain.step
  const here = terrain.heightAt(x, z)
  const east = terrain.tileAt(x + step, z) ? terrain.heightAt(x + step, z) : null
  const west = terrain.tileAt(x - step, z) ? terrain.heightAt(x - step, z) : null
  const south = terrain.tileAt(x, z + step) ? terrain.heightAt(x, z + step) : null
  const north = terrain.tileAt(x, z - step) ? terrain.heightAt(x, z - step) : null
  out.x = difference(west, here, east, step)
  out.y = difference(north, here, south, step)
  return out
}

function difference(before, here, after, step) {
  if (before !== null && after !== null) return (after - before) / (2 * step)
  if (after !== null) return (after - here) / step
  if (before !== null) return (here - before) / step
  return 0
}

function smoothstep(value, from, to) {
  const t = Math.min(Math.max((value - from) / (to - from), 0), 1)
  return t * t * (3 - 2 * t)
}

const VERTEX = new THREE.Vector3()
const NORMAL = new THREE.Vector3()
const SLOPE = new THREE.Vector2()
const COLOUR = new THREE.Color()
