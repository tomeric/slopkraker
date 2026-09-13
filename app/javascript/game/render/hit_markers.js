import * as THREE from "three"
import { createLabel, drawLabel, disposeLabel } from "game/render/gizmo_label"

// Floating damage numbers left where something was actually hit. Used for blasts, whose
// hitbox vanishes on detonation and so cannot flash the way a bolted-on part does.
export class HitMarkers {
  constructor(scene, hold) {
    this.scene = scene
    this.hold = hold
    this.live = []
    this.visible = true
  }

  add(position, damage, title = "BLAST") {

    const label = createLabel({ scale: [ 1.4, 0.7 ] })
    label.sprite.position.copy(position)
    drawLabel(label, { title, value: Math.round(damage), footer: "dealt", armed: true })
    this.scene.add(label.sprite)

    this.live.push({ label, remaining: this.hold })
  }

  update(dt) {
    for (let i = this.live.length - 1; i >= 0; i -= 1) {
      const marker = this.live[i]
      marker.remaining -= dt

      if (marker.remaining <= 0) {
        marker.label.sprite.removeFromParent()
        disposeLabel(marker.label)
        this.live.splice(i, 1)
        continue
      }

      // Drift upward and fade so overlapping hits stay readable.
      marker.label.sprite.position.y += dt * 1.1
      marker.label.sprite.material.opacity = Math.min(marker.remaining / (this.hold * 0.4), 1)
    }
  }

  dispose() {
    for (const marker of this.live) {
      marker.label.sprite.removeFromParent()
      disposeLabel(marker.label)
    }
    this.live = []
  }
}
