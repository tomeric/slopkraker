import * as THREE from "three"

// One InstancedMesh per material, holding every piece made of it.
//
// Not a BatchedMesh. Without the WEBGL_multi_draw extension three falls back to one draw
// call plus a uniform upload PER INSTANCE, which is strictly worse than separate meshes,
// and whether headless Chrome's software renderer exposes that extension is not something
// to bet the whole render path on. InstancedMesh is WebGL2 core and always one draw call.
//
// Every piece is the same unit cube, scaled and rotated by its instance matrix. One
// geometry, one material, one draw call per material, for a building made of hundreds of
// pieces.

// THE TRAP, and it costs a day if it is not written down. setColorAt is a silent no-op
// unless material.vertexColors is true -- USE_COLOR comes from nothing else. But turning
// it on makes the shader declare `attribute vec3 color` and multiply by it, and
// MeshStandardMaterial has no defaultAttributeValues, so an unbound attribute reads as the
// WebGL generic default and the entire building renders black.
//
// So the geometry carries a constant-1.0 colour of its own. Then instanceColor is a pure
// multiplier: the shared material keeps the base colour and is never mutated, and the
// instance carries damage darkening. That is what lets one material serve every piece --
// the old code had to give every prop its own material precisely because it tinted by
// mutating one.
function unitCube() {
  return withVertexColour(new THREE.BoxGeometry(1, 1, 1))
}

// See the note above: vertexColors is on for every one of these materials, so any geometry
// handed to a pool needs a constant-1.0 colour of its own or it renders black.
function withVertexColour(geometry) {
  if (geometry.getAttribute("color")) return geometry

  const white = new Float32Array(geometry.attributes.position.count * 3).fill(1)
  geometry.setAttribute("color", new THREE.BufferAttribute(white, 3))
  return geometry
}

// A pool named `rubble#2` is still made of `rubble`. The suffix picks a shape, never a
// material -- colour, health and everything else stay the material's.
export function baseMaterial(name) {
  const cut = name.indexOf("#")
  return cut < 0 ? name : name.slice(0, cut)
}

export class PieceMeshes {
  constructor(scene, materialSpecs, { looks = null } = {}) {
    this.scene = scene
    this.specs = materialSpecs
    this.looks = looks
    this.geometry = unitCube()
    this.pools = new Map()
    // Pools whose shape is not the unit cube. A wall panel is a box and every one of them
    // shares a single geometry; a heap of rubble is a lump, and there are several lumps so
    // that no two heaps read the same. Keyed by pool name, so a pool can carry a shape
    // without the material table knowing anything about it.
    this.shapes = new Map()
  }

  // Must be called before allocate: the geometry is handed to the InstancedMesh when the
  // pool is built and an InstancedMesh cannot be given a different one afterwards.
  useShape(name, geometry) {
    this.shapes.set(name, withVertexColour(geometry))
  }

  // The geometry a pool draws with, so something that wants to draw one more of the same
  // chunk outside the pool -- a remnant left lying after its heap is cleared -- draws the
  // very shape the pool did.
  shapeOf(name) {
    return this.shapes.get(name) || this.geometry
  }

  // Sized up front from the counts the caller has already tallied, because an
  // InstancedMesh cannot grow: its buffers are allocated once at its declared capacity.
  allocate(counts) {
    for (const [ name, count ] of counts) {
      if (count === 0) continue

      // Every pool owns a copy of its geometry, because a per-instance attribute lives on
      // the geometry and the pools do not share instance counts. A unit cube is 24
      // vertices; copying it a dozen times costs nothing.
      const geometry = (this.shapes.get(name) || this.geometry).clone()
      // Each instance's offset along its surface in metres, read by the metres shader
      // chunk (looks.js) so a brick bond runs on across the cells of a wall.
      geometry.setAttribute("cellUV", new THREE.InstancedBufferAttribute(new Float32Array(count * 2), 2))

      const mesh = new THREE.InstancedMesh(geometry, this.materialFor(name), count)
      mesh.name = `pieces:${name}`
      mesh.castShadow = true
      mesh.receiveShadow = true
      mesh.count = 0
      // Assigned by hand so three never walks every instance to work it out. It is
      // recomputed once the pool is full.
      mesh.frustumCulled = false
      this.scene.add(mesh)
      // `live` is how many of this pool's instances are actually showing. A zero-scale
      // instance rasterises nothing but the POOL still costs a draw call, so a pool with
      // nothing in it is switched off entirely -- which is what stops sixteen shapes of
      // rubble being sixteen draw calls in a world where nothing has fallen down yet.
      //
      // `base` is what each instance is coloured before damage: the palette's colour for
      // the material's role, with its jitter. Damage darkening multiplies it (tint), so it
      // has to be kept rather than read back off the instanceColor it has already dimmed.
      this.pools.set(name, { mesh, geometry, next: 0, live: 0, shown: new Uint8Array(count), base: new Float32Array(count * 3).fill(1) })
    }
  }

  // Colour WHITE, always: the instance carries the colour, which is how one pool serves
  // every palette. At high quality the material is dressed in the material's look --
  // albedo, normal and roughness maps painted at boot -- and at low it stays flat, so the
  // suite's timing assertions stand on the fragment cost they were measured at.
  materialFor(name) {
    const base = baseMaterial(name)
    const spec = this.specs[name] || this.specs[base] || {}
    const material = new THREE.MeshStandardMaterial({
      color: "#ffffff",
      roughness: spec.roughness ?? 0.85,
      metalness: spec.metalness ?? 0.05,
      transparent: (spec.opacity ?? 1) < 1,
      opacity: spec.opacity ?? 1,
      // See the note above unitCube: without this setColorAt does nothing at all.
      vertexColors: true
    })
    return this.looks ? this.looks.apply(material, base) : material
  }

  // Returns the instance slot, which the caller keeps so it can hide the piece later.
  // `colour` is the piece's base tint; `cellU`/`cellV` its offset along its surface in
  // metres.
  add(name, matrix, colour = WHITE, cellU = 0, cellV = 0) {
    const pool = this.pools.get(name)
    if (!pool) return -1

    const slot = pool.next
    pool.next += 1
    pool.mesh.count = pool.next
    pool.mesh.setMatrixAt(slot, matrix)
    pool.base[slot * 3] = colour.r
    pool.base[slot * 3 + 1] = colour.g
    pool.base[slot * 3 + 2] = colour.b
    pool.mesh.setColorAt(slot, colour)
    pool.geometry.attributes.cellUV.setXY(slot, cellU, cellV)
    pool.shown[slot] = 1
    pool.live += 1
    pool.mesh.visible = true
    return slot
  }

  // Damage darkening, over the base tint. instanceColor multiplies the material's own,
  // and that multiplication happens in linear space.
  tint(name, slot, ratio) {
    const pool = this.pools.get(name)
    if (!pool || slot < 0) return

    const shade = 0.35 + 0.65 * Math.max(Math.min(ratio, 1), 0)
    pool.mesh.setColorAt(slot, SCRATCH_COLOUR.setRGB(pool.base[slot * 3] * shade, pool.base[slot * 3 + 1] * shade, pool.base[slot * 3 + 2] * shade))
    pool.mesh.instanceColor.needsUpdate = true
  }

  // Readouts for the tests: where an instance's texture starts and what it was coloured.
  cellUVAt(name, slot) {
    const pool = this.pools.get(name)
    if (!pool || slot < 0) return null
    const attribute = pool.geometry.attributes.cellUV
    return [ attribute.getX(slot), attribute.getY(slot) ]
  }

  baseAt(name, slot, target = SCRATCH_COLOUR) {
    const pool = this.pools.get(name)
    if (!pool || slot < 0) return null
    return target.setRGB(pool.base[slot * 3], pool.base[slot * 3 + 1], pool.base[slot * 3 + 2])
  }

  // Hiding rather than removing. A zero-scale instance rasterises nothing, the slot stays
  // put, and putting the piece back is the same operation in reverse -- which is what the
  // server having the last word on a break requires.
  setVisible(name, slot, visible, matrix) {
    const pool = this.pools.get(name)
    if (!pool || slot < 0) return

    if (visible && matrix) {
      pool.mesh.setMatrixAt(slot, matrix)
    } else {
      pool.mesh.getMatrixAt(slot, SCRATCH_MATRIX)
      SCRATCH_MATRIX.scale(ZERO)
      pool.mesh.setMatrixAt(slot, SCRATCH_MATRIX)
    }
    pool.mesh.instanceMatrix.needsUpdate = true

    const now = visible ? 1 : 0
    if (pool.shown[slot] !== now) {
      pool.shown[slot] = now
      pool.live += now ? 1 : -1
      pool.mesh.visible = pool.live > 0
    }
  }

  finalise() {
    for (const { mesh } of this.pools.values()) {
      mesh.instanceMatrix.needsUpdate = true
      mesh.geometry.attributes.cellUV.needsUpdate = true
      if (mesh.instanceColor) mesh.instanceColor.needsUpdate = true
      mesh.computeBoundingSphere()
      mesh.frustumCulled = true
    }
  }

  get drawCalls() {
    return this.pools.size
  }

  dispose() {
    for (const { mesh, geometry } of this.pools.values()) {
      mesh.removeFromParent()
      mesh.material.dispose()
      mesh.dispose()
      // The pool's own copy, made in allocate so it could carry cellUV. The shape it was
      // cloned from is disposed below, once, however many pools share it.
      geometry.dispose()
    }
    for (const shape of this.shapes.values()) shape.dispose()
    this.pools.clear()
    this.shapes.clear()
    this.geometry.dispose()
  }
}

const WHITE = new THREE.Color(1, 1, 1)
const ZERO = new THREE.Vector3(0, 0, 0)
const SCRATCH_COLOUR = new THREE.Color()
const SCRATCH_MATRIX = new THREE.Matrix4()
