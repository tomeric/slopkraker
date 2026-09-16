import * as THREE from "three"

// The couple of pieces of rubbish a cleared heap leaves lying where it was.
//
// A heap is an instanced piece and vanishes in the frame it breaks, which is right for a
// wall panel and wrong for a pile of garbage: a heap you drove through should leave a few
// chunks of itself behind that settle onto the ground, lie there a moment, and then fade
// away into it. These are those chunks.
//
// Plain meshes with a material EACH, not instances, because fading is a per-piece opacity
// and an InstancedMesh has one material. That is only affordable because there are never
// many -- three per heap, gone in four seconds -- and it is why the pool has a hard cap
// that retires the oldest rather than refusing the new.
//
// Purely local. Nothing about a remnant crosses the wire: the heap it came from is what
// is shared, and by the time one of these exists that heap is already gone everywhere.
export class Remnants {
  constructor({ scene, materials, rules = {}, cap = 96 }) {
    this.scene = scene
    this.materials = materials
    this.settleTime = rules.settle ?? 0.35
    this.lingerTime = rules.linger ?? 2.0
    this.fadeTime = rules.fade ?? 1.5
    this.cap = cap
    this.live = []
    this.pool = []
    this.templates = new Map()
  }

  templateFor(name) {
    if (this.templates.has(name)) return this.templates.get(name)

    const spec = this.materials[name] || {}
    const material = new THREE.MeshStandardMaterial({
      color: spec.colour || "#888888",
      roughness: spec.roughness ?? 0.85,
      metalness: spec.metalness ?? 0.05,
      opacity: spec.opacity ?? 1
    })
    this.templates.set(name, material)
    return material
  }

  // `matrix` is the chunk's transform as it lay in the heap. The geometry is the pool's
  // own, shared, so a remnant is the very chunk that was drawn there a frame ago.
  add(geometry, name, matrix) {
    if (this.live.length >= this.cap) this.retire(this.live[0], 0)

    const template = this.templateFor(name)
    const entry = this.take()
    const mesh = entry.mesh
    matrix.decompose(mesh.position, mesh.quaternion, mesh.scale)
    mesh.geometry = geometry
    mesh.material.copy(template)
    mesh.material.transparent = true
    mesh.material.opacity = template.opacity
    mesh.visible = true

    entry.age = 0
    entry.from = mesh.position.y
    entry.opacity = template.opacity
    // Where it comes to rest once the lump under it has gone: on the ground, a little into
    // it. Local y is the chunk's thickness and stays roughly up, so that is its height.
    // The ground is flat at y = 0 for every world so far, as it is for the shards.
    entry.rest = Math.max(mesh.scale.y, 0.05) * 0.35
    entry.depth = mesh.scale.length() * 0.6
    this.live.push(entry)
    return entry
  }

  take() {
    const entry = this.pool.pop()
    if (entry) return entry

    const mesh = new THREE.Mesh(PLACEHOLDER, new THREE.MeshStandardMaterial({ transparent: true }))
    mesh.castShadow = true
    mesh.receiveShadow = false
    this.scene.add(mesh)
    return { mesh, age: 0, from: 0, rest: 0, depth: 0, opacity: 1 }
  }

  // Settle, linger, then fade while sinking. The sink is deliberately not a scale fade:
  // the chunk's scale is what gives it its shape, and shrinking it would turn a plank back
  // into a cube on its way out.
  update(dt) {
    for (let i = this.live.length - 1; i >= 0; i -= 1) {
      const entry = this.live[i]
      const mesh = entry.mesh
      entry.age += dt

      if (entry.age < this.settleTime) {
        const t = ease(entry.age / this.settleTime)
        mesh.position.y = entry.from + (entry.rest - entry.from) * t
        continue
      }

      const fading = entry.age - this.settleTime - this.lingerTime
      if (fading < 0) {
        mesh.position.y = entry.rest
        continue
      }
      if (fading >= this.fadeTime) {
        this.retire(entry, i)
        continue
      }

      const f = fading / this.fadeTime
      mesh.material.opacity = entry.opacity * (1 - f)
      mesh.position.y = entry.rest - entry.depth * f
    }
  }

  retire(entry, index = this.live.indexOf(entry)) {
    if (index < 0) return

    entry.mesh.visible = false
    this.live.splice(index, 1)
    this.pool.push(entry)
  }

  get count() {
    return this.live.length
  }

  dispose() {
    for (const entry of [ ...this.live, ...this.pool ]) {
      entry.mesh.removeFromParent()
      entry.mesh.material.dispose()
    }
    for (const material of this.templates.values()) material.dispose()
    this.live = []
    this.pool = []
    this.templates.clear()
  }
}

function ease(t) {
  return 1 - (1 - t) * (1 - t)
}

const PLACEHOLDER = new THREE.BoxGeometry(1, 1, 1)
