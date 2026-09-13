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
  const geometry = new THREE.BoxGeometry(1, 1, 1)
  const white = new Float32Array(geometry.attributes.position.count * 3).fill(1)
  geometry.setAttribute("color", new THREE.BufferAttribute(white, 3))
  return geometry
}

export class PieceMeshes {
  constructor(scene, materialSpecs) {
    this.scene = scene
    this.specs = materialSpecs
    this.geometry = unitCube()
    this.pools = new Map()
  }

  // Sized up front from the counts the caller has already tallied, because an
  // InstancedMesh cannot grow: its buffers are allocated once at its declared capacity.
  allocate(counts) {
    for (const [ name, count ] of counts) {
      if (count === 0) continue

      const mesh = new THREE.InstancedMesh(this.geometry, this.materialFor(name), count)
      mesh.name = `pieces:${name}`
      mesh.castShadow = true
      mesh.receiveShadow = true
      mesh.count = 0
      // Assigned by hand so three never walks every instance to work it out. It is
      // recomputed once the pool is full.
      mesh.frustumCulled = false
      this.scene.add(mesh)
      this.pools.set(name, { mesh, next: 0 })
    }
  }

  materialFor(name) {
    const spec = this.specs[name] || {}
    return new THREE.MeshStandardMaterial({
      color: spec.colour || "#888888",
      roughness: spec.roughness ?? 0.85,
      metalness: spec.metalness ?? 0.05,
      transparent: (spec.opacity ?? 1) < 1,
      opacity: spec.opacity ?? 1,
      // See the note above unitCube: without this setColorAt does nothing at all.
      vertexColors: true
    })
  }

  // Returns the instance slot, which the caller keeps so it can hide the piece later.
  add(name, matrix) {
    const pool = this.pools.get(name)
    if (!pool) return -1

    const slot = pool.next
    pool.next += 1
    pool.mesh.count = pool.next
    pool.mesh.setMatrixAt(slot, matrix)
    pool.mesh.setColorAt(slot, WHITE)
    return slot
  }

  // Damage darkening. A ratio rather than an absolute colour: instanceColor multiplies
  // the material's own, and that multiplication happens in linear space.
  tint(name, slot, ratio) {
    const pool = this.pools.get(name)
    if (!pool || slot < 0) return

    const shade = 0.35 + 0.65 * Math.max(Math.min(ratio, 1), 0)
    pool.mesh.setColorAt(slot, SCRATCH_COLOUR.setRGB(shade, shade, shade))
    pool.mesh.instanceColor.needsUpdate = true
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
  }

  finalise() {
    for (const { mesh } of this.pools.values()) {
      mesh.instanceMatrix.needsUpdate = true
      if (mesh.instanceColor) mesh.instanceColor.needsUpdate = true
      mesh.computeBoundingSphere()
      mesh.frustumCulled = true
    }
  }

  get drawCalls() {
    return this.pools.size
  }

  dispose() {
    for (const { mesh } of this.pools.values()) {
      mesh.removeFromParent()
      mesh.material.dispose()
      mesh.dispose()
    }
    this.pools.clear()
    this.geometry.dispose()
  }
}

const WHITE = new THREE.Color(1, 1, 1)
const ZERO = new THREE.Vector3(0, 0, 0)
const SCRATCH_COLOUR = new THREE.Color()
const SCRATCH_MATRIX = new THREE.Matrix4()
