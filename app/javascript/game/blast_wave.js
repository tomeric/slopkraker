import * as THREE from "three"
import { explosionForce } from "game/damage"

// Re-sweep once the shell has grown by this share of its final radius. The shell only
// grows and each target is caught at most once, so sweeping less often cannot change what
// a blast does -- explosionForce is a function of distance, not of time, so a target
// caught a tick later takes exactly the damage it would have taken a tick earlier. See
// the note above explosionRadius in damage.js, which makes the same argument for the
// easing curve.
const SWEEP_GROWTH = 0.08

// What an expanding explosion does to the world. The Explosions class owns what a blast
// *is* -- its radius over time, its shell, its readout; this owns what it *does*.
//
// Lives beside destruction.js rather than inside it until that file splits, at which
// point both move into destruction/.
export class BlastWave {
  constructor({ props, destruction, projectiles, grid, rules }) {
    this.props = props
    this.destruction = destruction
    this.projectiles = projectiles
    this.grid = grid
    this.rules = rules
    this.positionOf = (prop) => prop.entry?.currPos
  }

  apply(explosion, vehicle) {
    const { spec, at, damage, hit, radius } = explosion

    // Rockets and the vehicle are checked every step. Both move fast enough that catching
    // them a tick late would change what a blast chains into, and there are never more
    // than a handful of them, so there is nothing to save here anyway.
    this.chainRockets(at, hit, radius)
    this.shoveVehicle(spec, at, damage, hit, radius, vehicle)

    const sweptTo = explosion.sweptRadius || 0
    if (sweptTo >= spec.radius) return
    if (radius < spec.radius && radius - sweptTo < spec.radius * SWEEP_GROWTH) return

    // Props are knocked about by what hits them, so their cached positions have to catch
    // up before the sweep trusts them. Cheap: the positions come from the interpolator's
    // readback, so this never crosses into wasm.
    this.grid.refreshDynamic(this.positionOf)
    this.sweepProps(spec, at, damage, hit, radius, sweptTo)
    explosion.sweptRadius = radius
  }

  // Everything the shell has reached but not yet caught, and the further out it is the
  // weaker what arrives -- the same falloff a one-shot blast query gave, now spread over
  // the expansion.
  sweepProps(spec, at, damage, hit, radius, sweptTo) {
    this.grid.forEachInAnnulus(at.x, at.z, sweptTo, radius, (target, px, py, pz) => {
      if (hit.has(target)) return

      const dx = px - at.x, dy = py - at.y, dz = pz - at.z
      const distance = Math.hypot(dx, dy, dz)
      if (distance > radius) return

      hit.add(target)
      const falloff = explosionForce(spec, distance)

      // The grid holds both the loose props and the pieces of every building. A piece has
      // a building; a prop has a body.
      if (target.building) {
        this.blastPiece(target, damage * falloff, dx, dy, dz, distance)
        return
      }

      if (target.broken) return
      this.destruction.apply(target, damage * falloff)
      // The blast may have just destroyed it; its body is gone.
      if (target.broken) return

      push(target.body, dx, dy, dz, distance, falloff * damage * spec.prop_push, spec.prop_lift, 0.4)
    })
  }

  // A piece is fixed, so there is nothing to shove -- the whole effect is the damage and
  // what it throws off. `away` points out of the blast so the shards carry with it.
  blastPiece(target, damage, dx, dy, dz, distance) {
    const away = AWAY.set(dx, dy, dz)
    if (distance > 0) away.multiplyScalar(1 / distance)

    // Handed over raw and marked as a blast: each cell it reaches absorbs it with its own
    // material, so glass and the lintel beside it answer for themselves.
    const building = target.building
    building.damage(target.piece, damage, "blast", building.spread, away)
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

const AWAY = new THREE.Vector3()

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
