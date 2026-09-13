import { explosionForce } from "game/damage"

// What an expanding explosion does to the world. The Explosions class owns what a blast
// *is* -- its radius over time, its shell, its readout; this owns what it *does*.
//
// Lives beside destruction.js rather than inside it until that file splits, at which
// point both move into destruction/.
//
// Each target is caught once, on the frame the shell reaches it, and the further out it
// is the weaker what arrives -- the same falloff a one-shot blast query gave, now spread
// over the expansion. The caller's `hit` set is what makes "once" true across frames.
export class BlastWave {
  constructor({ props, destruction, projectiles }) {
    this.props = props
    this.destruction = destruction
    this.projectiles = projectiles
  }

  apply(explosion, vehicle) {
    const { spec, at, damage, hit, radius } = explosion

    this.sweepProps(spec, at, damage, hit, radius)
    this.chainRockets(at, hit, radius)
    this.shoveVehicle(spec, at, damage, hit, radius, vehicle)
  }

  sweepProps(spec, at, damage, hit, radius) {
    for (const prop of this.props) {
      if (prop.broken || hit.has(prop)) continue

      const t = prop.body.translation()
      const dx = t.x - at.x, dy = t.y - at.y, dz = t.z - at.z
      const distance = Math.hypot(dx, dy, dz)
      if (distance > radius) continue

      hit.add(prop)
      const falloff = explosionForce(spec, distance)
      this.destruction.apply(prop, damage * falloff)
      // The blast may have just destroyed it; its body is gone.
      if (prop.broken) continue

      push(prop.body, dx, dy, dz, distance, falloff * damage * spec.prop_push, spec.prop_lift, 0.4)
    }
  }

  // A rocket caught in a blast goes off with it, so a burst chains rather than trickling
  // into the scenery one at a time. It dies here and detonates on the next projectile
  // update, which is also what keeps the chain from recursing mid-frame.
  chainRockets(at, hit, radius) {
    for (const rocket of this.projectiles.live) {
      if (rocket.dead || hit.has(rocket)) continue

      const t = rocket.body.translation()
      if (Math.hypot(t.x - at.x, t.y - at.y, t.z - at.z) > radius) continue

      hit.add(rocket)
      this.projectiles.markDead(rocket)
    }
  }

  // Blasts shove the vehicle too -- rocket-jumping off your own shot is a feature.
  shoveVehicle(spec, at, damage, hit, radius, vehicle) {
    if (!vehicle || hit.has(vehicle)) return

    const t = vehicle.body.translation()
    const dx = t.x - at.x, dy = t.y - at.y, dz = t.z - at.z
    const distance = Math.hypot(dx, dy, dz)
    if (distance > radius) return

    hit.add(vehicle)
    const falloff = explosionForce(spec, distance)
    push(vehicle.body, dx, dy, dz, distance, falloff * damage * spec.vehicle_push, spec.vehicle_lift, 0.6)
  }
}

// `lift` is the upward bias that makes a blast throw things up rather than merely slide
// them along the ground. `floor` keeps a target sitting exactly on the origin from being
// launched into orbit by a division by nearly zero; the vehicle's is larger than a prop's
// because it is so much heavier that the same impulse reads as less of a shove.
function push(body, dx, dy, dz, distance, magnitude, lift, floor) {
  const inverse = 1 / Math.max(distance, floor)
  body.applyImpulse(
    {
      x: dx * inverse * magnitude,
      y: (dy * inverse + lift) * magnitude,
      z: dz * inverse * magnitude
    },
    true
  )
}
