import * as THREE from "three"
import { explosionRadius } from "game/damage"
import { createLabel, drawLabel, disposeLabel, wireBox, ARMED_COLOUR } from "game/render/gizmo_label"

// The blast a rocket leaves behind: an object with a life of its own rather than an
// instant of damage. The shell expands from a point out to the spec radius, and whatever
// it reaches takes a share of the damage scaled by how far out it had to travel -- so the
// falloff is the same one an instant blast query gives, except it now happens over time
// and can be watched.
//
// This class owns what an explosion IS: how big it is, what it looks like, what it reads
// out. What it DOES to the world stays in the engine, which already owns the props, the
// vehicle and the destruction rules.
export class Explosions {
  constructor({ scene, onWave }) {
    this.scene = scene
    this.onWave = onWave || (() => {})
    this.live = []
    this.fired = 0
    this.debugVisible = true

    // Unit sphere, scaled per frame: rebuilding geometry as it grows is a lot of garbage
    // for something that only ever changes size.
    this.geometry = new THREE.SphereGeometry(1, 20, 14)
  }

  spawn({ at, spec, damage }) {
    const mesh = new THREE.Mesh(
      this.geometry,
      new THREE.MeshBasicMaterial({
        color: spec.colour,
        transparent: true,
        opacity: 0.55,
        depthWrite: false,
        blending: THREE.AdditiveBlending
      })
    )
    mesh.position.copy(at)
    mesh.scale.setScalar(0.001)
    this.scene.add(mesh)

    const explosion = {
      at: at.clone(), spec, damage, age: 0, radius: 0,
      // Each target is caught once, as the shell reaches it -- a set rather than a
      // distance band, so something moving through the blast cannot be hit twice.
      hit: new Set(),
      mesh,
      ...this.buildGizmo(spec)
    }

    this.live.push(explosion)
    this.fired += 1
    return explosion
  }

  // Built at full size and scaled down, the same way the shell is, so the overlay always
  // draws the reach the blast has right now.
  buildGizmo(spec) {
    const extent = spec.radius * 2
    const box = wireBox([ extent, extent, extent ], ARMED_COLOUR)
    box.visible = this.debugVisible
    this.scene.add(box)

    const label = createLabel({ scale: [ 1.4, 0.7 ] })
    label.sprite.visible = this.debugVisible
    this.scene.add(label.sprite)

    return { box, label }
  }

  update(dt) {
    for (let i = this.live.length - 1; i >= 0; i -= 1) {
      const explosion = this.live[i]
      explosion.age += dt
      explosion.radius = explosionRadius(explosion.spec, explosion.age)

      this.onWave(explosion)

      if (explosion.age >= explosion.spec.expand_time + explosion.spec.linger) {
        this.remove(explosion)
        this.live.splice(i, 1)
      }
    }
  }

  // Full strength while it expands, then fading away over the linger.
  fadeOf(explosion) {
    const { expand_time: expand, linger } = explosion.spec
    if (explosion.age <= expand || linger <= 0) return 1

    return Math.max(1 - (explosion.age - expand) / linger, 0)
  }

  sync() {
    for (const explosion of this.live) {
      explosion.mesh.scale.setScalar(Math.max(explosion.radius, 0.001))
      explosion.mesh.material.opacity = 0.55 * this.fadeOf(explosion)

      explosion.box.visible = this.debugVisible
      explosion.label.sprite.visible = this.debugVisible
      if (!this.debugVisible) continue

      explosion.box.position.copy(explosion.at)
      explosion.box.scale.setScalar(
        Math.max(explosion.radius / explosion.spec.radius, 0.001)
      )
      explosion.label.sprite.position.set(
        explosion.at.x, explosion.at.y + 1.2, explosion.at.z
      )

      drawLabel(explosion.label, {
        title: "BLAST",
        value: Math.round(explosion.damage),
        footer: `${explosion.radius.toFixed(1)}m`,
        armed: true
      })
    }
  }

  readout() {
    return this.live.map((e) => ({
      damage: Math.round(e.damage),
      radius: +e.radius.toFixed(2),
      age: +e.age.toFixed(2)
    }))
  }

  remove(explosion) {
    explosion.mesh.removeFromParent()
    explosion.mesh.material.dispose()
    explosion.box.removeFromParent()
    explosion.box.geometry.dispose()
    explosion.box.material.dispose()
    explosion.label.sprite.removeFromParent()
    disposeLabel(explosion.label)
  }

  dispose() {
    for (const explosion of this.live) this.remove(explosion)
    this.live = []
    this.geometry.dispose()
  }
}
