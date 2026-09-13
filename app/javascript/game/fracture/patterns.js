import * as THREE from "three"
import { DestructibleMesh, FractureOptions } from "@dgreenheck/three-pinata"

// A library of fracture patterns, one per material, baked from a UNIT CUBE.
//
// Baking in normalised space is what makes this affordable. A pattern is generated once
// for brick and once for glass, and then every brick panel in the world reuses it, scaled
// into whatever box that panel happens to occupy. The alternative -- fracturing each piece
// as it breaks -- means running a Voronoi tessellation on the frame a wall is hit, which
// is exactly the frame that can least afford it.
//
// Anisotropic scaling does skew a fragment's silhouette. At debris scale, tumbling, for a
// couple of seconds, nobody has ever noticed.
//
// Baked during startup, not on first use. Lazy baking sounds cheaper and is much worse in
// practice: the first break of a material is almost never a single panel. A rocket takes
// out brick, glass, timber and a lintel in the same frame, so the first explosion pays for
// four tessellations at once -- which is a visible stutter, at the exact moment the player
// is looking at the thing that caused it. Paying it during the loading screen instead
// costs the same total and is invisible.

// Above this, a fracture is not worth watching and the debris budget eats it anyway.
const MAX_FRAGMENTS = 24

export class Patterns {
  constructor(materials) {
    this.materials = materials
    this.cache = new Map()
    this.unitCube = new THREE.BoxGeometry(1, 1, 1)
  }

  // Bake everything the world can actually break, up front. Anything missed still falls
  // back to lazy baking, so a material that only appears later is a hitch rather than a
  // crash.
  warm(names) {
    for (const name of names) this.for(name)
    return this
  }

  // Fragment geometries for a material, in unit-cube space. Cached forever.
  for(name) {
    if (this.cache.has(name)) return this.cache.get(name)

    const fragments = this.bake(name)
    this.cache.set(name, fragments)
    return fragments
  }

  bake(name) {
    const spec = this.materials[name]
    const fracture = spec?.fracture || {}
    if (fracture.method === "none") return []

    try {
      return this.tessellate(fracture)
    } catch (error) {
      // A fracture that fails is a visual loss, not a broken game. Falling back to a
      // simple split keeps debris appearing rather than letting one bad tessellation take
      // the whole break with it.
      console.warn(`[fracture] ${name} fell back to a simple split:`, error)
      return this.simpleSplit()
    }
  }

  tessellate(fracture) {
    const mesh = new DestructibleMesh(this.unitCube.clone())
    const count = Math.min(fracture.fragments || 8, MAX_FRAGMENTS)

    const options = new FractureOptions({
      fractureMethod: fracture.method === "simple" ? "simple" : "voronoi",
      fragmentCount: count,
      // Timber splits along the grain rather than into cubes; the planes say which way the
      // grain runs.
      fracturePlanes: fracture.planes || { x: false, y: true, z: false },
      voronoiOptions: fracture.method === "simple" ? undefined : {
        // 2.5D for anything essentially flat -- a pane, a roof tile. Shards then run
        // through the thickness like real glass instead of being diced in every axis.
        mode: fracture.mode === "2.5D" ? "2.5D" : "3D",
        projectionAxis: "z",
        useApproximation: Boolean(fracture.approximate)
      },
      // Fixed, so a material's debris is the same every time. Variety comes from the
      // fragments being thrown differently, not from re-tessellating.
      seed: 1
    })

    const fragments = mesh.fracture(options).map((piece) => {
      piece.updateMatrix()
      const geometry = piece.geometry.clone()
      // Bake the fragment's own offset in, so a debris instance is one matrix rather than
      // a matrix plus a remembered origin.
      geometry.applyMatrix4(piece.matrix)
      piece.dispose()
      return geometry
    })

    mesh.dispose()
    return fragments.length > 0 ? fragments : this.simpleSplit()
  }

  // Eight cubes in the corners of the unit cube. What everything looked like before
  // three-pinata, and still the safety net underneath it.
  simpleSplit() {
    const out = []
    for (const x of [ -0.25, 0.25 ]) {
      for (const y of [ -0.25, 0.25 ]) {
        for (const z of [ -0.25, 0.25 ]) {
          const geometry = new THREE.BoxGeometry(0.5, 0.5, 0.5)
          geometry.translate(x, y, z)
          out.push(geometry)
        }
      }
    }
    return out
  }

  dispose() {
    for (const fragments of this.cache.values()) {
      for (const geometry of fragments) geometry.dispose()
    }
    this.cache.clear()
    this.unitCube.dispose()
  }
}
