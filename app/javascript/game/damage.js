// Faithful port of Game::DamageResolver. Ruby owns the rules; this evaluates them
// client-side so damage feedback is immediate rather than a network round trip away.
// Covered by a parity system test against the Ruby implementation.
//
// `material` is an entry from the table Ruby ships in the spec, or null for something
// that carries its own health -- a crate, a pillar. `kind` says how it was hit, because a
// blast and a blade are not the same thing to a pane of glass.
export function resolveDamage({ rules, part, speed, state, material = null, kind = "impact" }) {
  const excess = speed - rules.minimum_speed
  if (excess <= 0) return 0

  const raw = excess * rules.damage_per_speed * multiplierFor(part, state)
  if (!material) return raw

  return absorb(raw, material, kind, rules)
}

function multiplierFor(part, state) {
  if (!part) return 1
  if (!partArmed(part, state)) return 1
  return part.damage_multiplier
}

// What a material makes of a hit aimed at it. Shared, because a blast has to be absorbed
// by the same rules an impact is -- otherwise concrete resists being driven into and
// shrugs at explosives, or the other way round, depending on which path ran.
//
// Hardness comes off after the multipliers, not before: taking it first would let a big
// multiplier cancel it out. And never all the way to nothing -- a fixed share of every hit
// lands, so a very hard thing is a long job rather than a silently invincible one.
export function absorb(damage, material, kind, rules) {
  if (!material) return damage

  const hit = damage * (material.multipliers?.[kind] ?? 1)
  return Math.max(hit - material.hardness, hit * (rules.minimum_fraction ?? 0))
}

// Which kind of damage a part deals, for materials that care. A blade shears timber, a
// bull bar sweeps glass away, a slam drives straight down through a roof -- and concrete
// shrugs all three off. Anything without an opinion is a plain impact.
const PART_KINDS = {
  bulldozer_blade: "blade",
  bull_bar: "bull_bar",
  slam_plate: "slam"
}

export function partKind(part) {
  return (part && PART_KINDS[part.kind]) || "impact"
}

// Mirrors Part#armed? and its overrides.
export function partArmed(part, state = {}) {
  switch (part.kind) {
    case "bull_bar":
      // Only bites mid-drift: a deliberate manoeuvre, not a reverse bump. The grace
      // window keeps it alive briefly after the drift so a hit landing as you straighten
      // up still counts.
      if ((state.drift_grace || 0) > 0) return true
      if (!state.drifting) return false
      return Math.abs(state.slip_angle || 0) >= part.minimum_slip_angle

    case "slam_plate":
      // Only bites while the thruster is driving the truck down, and only once it has
      // built real speed -- settling gently onto something is not a slam.
      if (!state.slamming) return false
      return Math.abs(state.fall_speed || 0) >= part.minimum_speed

    default:
      return true
  }
}

// Rockets wind up after launch, so what one is worth depends on how fast it is going.
export function rocketDamage(spec, speed) {
  return Math.min(Math.max(spec.damage_per_speed * speed, spec.minimum_damage), spec.max_damage)
}

// Faithful port of Game::Explosion#radius_at. Eased out, so a blast leaps outward and
// settles rather than creeping at a constant rate. The curve is cosmetic and cannot move
// the numbers: damage is a function of distance, so it decides only WHEN something is
// caught, never how hard.
export function explosionRadius(spec, elapsed) {
  if (spec.expand_time <= 0) return spec.radius

  const t = Math.min(Math.max(elapsed / spec.expand_time, 0), 1)
  return spec.radius * (1 - (1 - t) ** 2)
}

// Faithful port of Game::Explosion#force_at: the share of the blast something at this
// distance takes. Everything at the centre, nothing at the rim.
export function explosionForce(spec, distance) {
  if (spec.radius <= 0) return 0

  return Math.min(Math.max(1 - distance / spec.radius, 0), 1)
}
