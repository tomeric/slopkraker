import { resolveDamage, partArmed } from "game/damage"
import { createLabel, drawLabel, disposeLabel, wireBox, ARMED_COLOUR, IDLE_COLOUR } from "game/render/gizmo_label"

const HIT_COLOUR = "#ff4d3d"
import * as THREE from "three"

// Wireframe hitboxes over every part that can deal damage, each labelled with what it
// would actually do if it connected right now.
//
// The numbers come from the same resolveDamage() the game applies, driven by the rules
// Ruby ships in the spec -- so the overlay cannot drift from real behaviour. A part whose
// bonus is conditional (the bull bar only bites mid-drift) dims and shows its unarmed
// value until the condition is met.
// Fast enough to catch short-lived states like a slam, which is over in a few frames.
const REFRESH_HZ = 20

export class DamageGizmos {
  constructor(parent, vehicleSpec, rules) {
    this.rules = rules
    this.hold = rules.damage_flash || 1.0
    this.group = new THREE.Group()
    this.group.name = "damage-gizmos"
    parent.add(this.group)

    this.elapsed = 0
    this.entries = []
    this.readout = []
    this.baseHeight = vehicleSpec.chassis.size[1] / 2 + 0.9

    // The chassis itself does damage at the base multiplier.
    const hittable = [
      { label: "CHASSIS", part: null, offset: [ 0, 0, 0 ], size: vehicleSpec.chassis.size },
      // Jets are an emitter, not a collider -- they cannot hit anything.
      ...vehicleSpec.parts
        .filter((part) => part.kind !== "jump_jets")
        .map((part) => ({
          label: part.name.replace(/_/g, " ").toUpperCase(),
          part,
          offset: part.offset,
          size: part.size
        }))
    ]

    hittable.forEach((spec, tier) => this.entries.push(this.build({ ...spec, tier })))
  }

  build({ label, part, offset, size, tier }) {
    const box = wireBox(size)
    box.position.set(offset[0], offset[1], offset[2])
    this.group.add(box)

    const gizmo = createLabel()
    // One column above the car's centre. Keeping each label over its own part looks
    // tidier until you view the car end-on, when the fore-and-aft offsets collapse into
    // the same screen position and the labels bury each other.
    gizmo.sprite.position.set(0, this.baseHeight + tier * 1.05, 0)
    this.group.add(gizmo.sprite)

    // Keyed by the collider's own name so impacts can be routed back to it.
    return { label, key: part ? part.name : "chassis", part, size, box, gizmo, hit: null }
  }

  // Called when this part actually connects with something. The box flashes and the
  // label holds the damage it really dealt, rather than the live prediction.
  registerHit(key, damage) {
    const rounded = Math.round(damage)
    // Grinding through a stack fires contact events all the way down to a nudge; a
    // sub-1 scrape is not what you want to read.
    if (rounded < 1) return

    const entry = this.entries.find((candidate) => candidate.key === key)
    if (!entry) return

    // Keep the biggest hit of the flash rather than the last one, or a real impact is
    // immediately overwritten by the scrape that follows it.
    if (entry.hit && entry.hit.damage > rounded) {
      entry.hit.remaining = this.hold
      return
    }

    entry.hit = { damage: rounded, remaining: this.hold }
  }

  update(dt, vehicle) {
    for (const entry of this.entries) {
      if (!entry.hit) continue
      entry.hit.remaining -= dt
      if (entry.hit.remaining <= 0) entry.hit = null
    }

    this.elapsed += dt
    if (this.elapsed < 1 / REFRESH_HZ) return
    this.elapsed = 0

    // Full 3D speed, not planar: GameEngine resolves real impacts from the relative
    // velocity of both bodies, so a slam straight down has to count as speed here too or
    // the overlay would read zero on the very hit it is meant to describe.
    const v = vehicle.body.linvel()
    const speed = Math.hypot(v.x, v.y, v.z)
    const state = vehicle.damageState()
    // Always computed, even while hidden: the HUD and the tests read it.
    this.readout = []

    for (const entry of this.entries) {
      const armed = entry.part ? partArmed(entry.part, state) : true
      const damage = resolveDamage({ rules: this.rules, part: entry.part, speed, state })
      const bonus = entry.part && armed ? entry.part.damage_multiplier : 1

      // The bull bar's collider grows mid-slide, so the box drawn over it has to follow or
      // the overlay would be describing a hitbox the car no longer has. Done before the
      // readout is taken, and regardless of whether the overlay is on screen, so what is
      // reported is always what would be drawn.
      if (entry.part?.kind === "bull_bar") this.resize(entry, vehicle.bullBarBox())

      this.readout.push({
        label: entry.label, damage: Math.round(damage), armed, bonus,
        hit: entry.hit ? entry.hit.damage : null,
        box: this.drawnBox(entry)
      })

      if (!this.group.visible) continue

      // A hit highlights the box and its label. The label keeps showing the live
      // prediction; what the hit actually dealt floats separately in the interface.
      const highlight = Boolean(entry.hit)
      entry.box.material.color.set(highlight ? HIT_COLOUR : damage > 0 && armed ? ARMED_COLOUR : IDLE_COLOUR)
      entry.box.material.opacity = highlight || damage > 0 ? 1 : 0.5

      drawLabel(entry.gizmo, {
        title: entry.label,
        value: Math.round(damage),
        // An unarmed part still does chassis-level damage; say what it is waiting for.
        footer: armed ? `x${bonus.toFixed(1)}` : this.waitingFor(entry.part),
        armed,
        highlight
      })
    }
  }

  // Scaled rather than rebuilt: an EdgesGeometry per frame is a lot of garbage for a box
  // that only ever changes size.
  resize(entry, live) {
    if (!live) return

    entry.box.scale.set(
      (live.halfWidth * 2) / entry.size[0],
      (live.halfHeight * 2) / entry.size[1],
      (live.halfDepth * 2) / entry.size[2]
    )
    entry.box.position.z = live.z
  }

  // Measured off the mesh itself rather than off what it was asked to be, so a box that
  // never took the change reads back as the box on screen.
  drawnBox(entry) {
    return {
      width: entry.size[0] * entry.box.scale.x,
      height: entry.size[1] * entry.box.scale.y,
      depth: entry.size[2] * entry.box.scale.z,
      z: entry.box.position.z
    }
  }

  waitingFor(part) {
    if (part?.kind === "slam_plate") return "needs slam"
    return "needs drift"
  }

  set visible(value) {
    this.group.visible = value
  }

  get visible() {
    return this.group.visible
  }

  dispose() {
    for (const entry of this.entries) {
      entry.box.geometry.dispose()
      entry.box.material.dispose()
      disposeLabel(entry.gizmo)
    }
    this.group.removeFromParent()
    this.entries = []
  }
}
