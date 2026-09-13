// Faithful port of Game::DamageResolver. Ruby owns the rules; this evaluates them
// client-side so damage feedback is immediate rather than a network round trip away.
// Covered by a parity system test against the Ruby implementation.
export function resolveDamage({ rules, part, speed, state }) {
  const excess = speed - rules.minimum_speed
  if (excess <= 0) return 0

  return excess * rules.damage_per_speed * multiplierFor(part, state)
}

function multiplierFor(part, state) {
  if (!part) return 1
  if (!partArmed(part, state)) return 1
  return part.damage_multiplier
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
