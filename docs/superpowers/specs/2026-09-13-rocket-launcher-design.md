# Rocket launcher: two-phase flight and expanding explosions

Date: 2026-09-13
Status: approved, not yet implemented

## Why

The buggy's rocket reads as a single flat dart. It leaves the rail and immediately
winds up, so the flight is one arc and the moment of ignition is invisible. When it
lands, the blast is an instantaneous radius query that draws nothing at all —
`hit_markers.js` says so outright: *"blasts, whose hitbox vanishes on detonation and
so cannot flash the way a bolted-on part does."*

The goal is a cartoon rocket: a lazy lob out of the launcher, a visible ignition near
the apex, then a second arc as the thrusters run. On impact it leaves a real
explosion — an object with a radius that grows, its own damage readout, and a force
that falls away as it expands.

## What exists today

- `Game::Rocket` carries one flight profile: `launch_speed`, `max_speed`,
  `acceleration`, `gravity_scale`, `blast_radius` and a damage curve.
- `projectiles.js` accelerates every rocket every frame toward `max_speed`. There is
  no coast phase and no notion of ignition.
- `engine.js#explode()` runs once per detonation: it walks the props and the vehicle,
  applies `damage × (1 − distance / blast_radius)`, and pushes bodies with four
  impulse scalars hardcoded in JS (`0.9`, `2.2`, `0.6`, `0.8`).
- The rocket mesh is a bare emissive capsule. No plume, no flame.
- A rocket already self-destructs at `lifetime` (5.0s) — `projectiles.js:92`.

## Design

### 1. Rocket flight profile (Ruby)

`Game::Rocket` gains a `flight` block. The two phases each carry **their own gravity
scale**; that, not the speed change alone, is what makes two arcs legible.

```ruby
flight: {
  coast:  { drag: 9.0, gravity_scale: 0.75, min_time: 0.15, max_time: 0.9 },
  thrust: { acceleration: 58.0, max_speed: 64.0, gravity_scale: 0.30 }
}
```

`max_speed`, `acceleration` and `gravity_scale` move off the top level into these
blocks. `launch_speed`, `mass`, `radius`, `lifetime`, `colour` and the damage curve
stay where they are.

Ignition fires when vertical velocity crosses zero — the apex — bounded at both ends:

- `min_time` guarantees a visible coast. Fired down a slope or off a ramp, `v.y` can
  already be negative on the first frame, which would light the motor instantly and
  collapse the effect back to one arc.
- `max_time` is the backstop for the opposite case. Fired from a fast-moving buggy,
  inherited velocity can mean the apex never arrives at all.

New/changed methods:

- `spin_up_time` now reads from `flight.thrust` (same arithmetic).
- `coast_speed_at(t)` → `launch_speed - drag × t`, floored at zero. Makes the coast
  unit-testable without a browser.

### 2. `Game::Explosion` (Ruby)

`blast_radius` leaves `Rocket` and becomes a model of its own, which also pulls the
four hardcoded impulse scalars out of `engine.js` and into the spec where this
codebase keeps its numbers.

```ruby
Explosion.new(
  radius: 4.5, expand_time: 0.22, linger: 0.20,
  prop_push: 0.9, prop_lift: 0.6,
  vehicle_push: 2.2, vehicle_lift: 0.8,
  colour: "#ffb03a"
)
```

A `Rocket` **holds an `Explosion`**, the way a `RocketLauncher` holds a `Rocket`:
`Rocket#explosion`, serialised at `rocket.explosion` in the spec. Every rocket
therefore carries the blast it will leave behind.

`prop_push` and `vehicle_push` scale the outward impulse per point of damage.
`prop_lift` and `vehicle_lift` are the upward bias added to that impulse — they are
what makes a blast throw debris up rather than merely sliding it along the ground,
and they are today's bare `0.6` and `0.8` in `engine.js`.

Methods:

- `radius_at(elapsed)` → eased out: `radius × (1 − (1 − t)²)`, `t = elapsed / expand_time`,
  clamped to `radius`.
- `force_at(distance)` → `(1 − distance / radius)`, clamped to `0..1`.
- `duration` → `expand_time + linger`.

**The easing curve is cosmetic and cannot affect balance.** Damage is a function of
distance, not of time, so the curve only decides *when* a target is reached, never how
hard it is hit.

**This preserves the current balance exactly.** A target at distance `d` is reached
when the shell is at `d/R` and takes `damage × (1 − d/R)` — algebraically identical to
today's instantaneous falloff. Same numbers; they now happen over time and are visible.

### 3. Flight phases in `projectiles.js`

Each rocket gains `phase` (`"coast"` or `"thrust"`). `update()` branches:

- **coast** — decelerate along the heading by `drag × dt`; ignite when
  `life >= min_time` and (`v.y <= 0` or `life >= max_time`). On ignition, set
  `phase = "thrust"` and `body.setGravityScale(thrust.gravity_scale)`.
- **thrust** — today's `accelerate()`, unchanged.

`spawn()` sets the body's gravity scale to `coast.gravity_scale`.

`damage` continues to track live speed, so a rocket caught mid-coast is worth less
than one that has been running — which the existing damage tests already assert.

### 4. `game/explosions.js` (new)

Built like `projectiles.js`: a `live` array, `spawn` / `update` / `sync` / `dispose`.
Each explosion holds position, spec, the rocket's damage at impact, age, current
radius, and a `Set` of already-damaged targets so the wave hits each once.

It owns **what an explosion is**:

- the radius over time,
- the expanding shell mesh (translucent, additive, fading through `linger`),
- the wireframe gizmo and damage label for the debug overlay,
- its entry in `stats.explosionReadout`.

### 5. `engine.js` wiring

`explode()` becomes `explosions.spawn({ at, spec, damage })`. The target loop it
already has — props, `destruction.apply`, the vehicle push — stays in the engine and
moves into an `onWave(explosion, previousRadius, radius)` callback, firing only for
targets inside the band the shell swept this frame.

This keeps **what an explosion does to the world** where that policy already lives,
and confines the new class to the entity and its visuals. `explode()` is refactored,
not rewritten.

### 6. `game/render/rocket_plume.js` (new)

One class owning the VFX for one rocket, using plain Three.js primitives — this
project ships no texture assets anywhere.

- **Flame**: an emissive cone at the tail, jittered and pulsed per frame. Visible
  **only during thrust**, so ignition is something you watch rather than infer.
- **Plume**: a ring buffer of small quads dropped along the flight path, shrinking and
  fading. Sparse while coasting, dense under power.

Kept out of `projectiles.js`, which is already 173 lines and would roughly double.

### 7. Telemetry and the debug overlay

- `rocketReadout` entries gain `phase`, making the two-arc claim measurable from tests.
- `stats.explosionReadout` is added: position, radius, damage, age per live explosion.
- Explosions draw their own gizmo and label, exactly as rockets do, so the expanding
  blast has "its own hitbox and damage numbers" in the overlay.

## Data flow

```
Buggy#fire
  └─> Projectiles.spawn   phase = coast, gravity = coast.gravity_scale
        └─> update(dt)    coast: decelerate; ignite at apex (bounded)
                          thrust: accelerate to max_speed
        └─> detonate      on contact, or at lifetime (5s air burst)
              └─> Explosions.spawn(at, spec.explosion, damage)
                    └─> update(dt)   radius = radius_at(age)
                          └─> onWave(explosion, prevRadius, radius)
                                └─> engine: damage + impulse each newly reached
                                    target once, scaled by force_at(distance)
```

## Edge cases

- **Fired downhill / off a ramp**: `v.y` already negative at spawn. `min_time` keeps a
  visible coast.
- **Fired from a fast-moving buggy**: inherited velocity may mean the apex never
  arrives. `max_time` ignites anyway.
- **Air burst**: a rocket that hits nothing detonates at `lifetime` and now spawns a
  real explosion in mid-air. Rarely reached in practice — ~4s of powered flight at up
  to 64 m/s meets an arena wall first.
- **Explosion spawned inside a prop**: distance 0, full damage, hit once.
- **Prop broken by an earlier wave**: skipped, as today.
- **Overlapping explosions**: each keeps its own hit set, so both can damage the same
  prop.
- **Blast through cover**: the shell is a distance check, not a collider, so it passes
  through walls. Today's radius query does the same — no regression, but now visible.

## Testing

Ruby unit (fast, no browser):

- `Game::Explosion`: `radius_at` starts at 0, reaches `radius`, never exceeds it;
  `force_at` is 1 at the centre, 0 at the rim, clamped beyond; `duration`.
- `Game::Rocket`: `coast_speed_at` sheds speed and floors at zero; `spin_up_time`
  still reads from thrust; a rocket cannot ignite before `min_time`.
- `world_test`: the buggy's rocket ships both flight phases and an explosion block;
  coast gravity is heavier than thrust gravity (the two-arc invariant); `min_time <
  max_time`.

System (Selenium, reading `window.__arena`):

- A rocket **slows** during coast, then **speeds up** after ignition — the two-arc
  claim, measured from `rocketReadout`.
- Vertical velocity crosses zero before `phase` flips to `thrust`.
- Ignition happens no later than `max_time`.
- A rocket fired into open air detonates by its spec `lifetime` (currently unasserted
  anywhere).
- An explosion appears in `explosionReadout`, its radius grows to the spec radius,
  then it disappears.
- A prop near the blast takes more damage than one far from it.

Screenshot check for the plume and flame, as with the bull bar spikes — nothing in
this repo can see the Three.js scene.

## Migration notes

Existing tests that must change when fields move:

- `test/models/game/rocket_test.rb` — the fixture uses the old flat kwargs, and
  *"serialises without leaking ruby objects"* asserts every value is `Numeric` or
  `String`, which nested `flight` / `explosion` hashes break. `world_test`'s
  `assert_no_ruby_objects` already handles nesting and is the better check.
- `test/models/game/parts/rocket_launcher_test.rb` — same fixture.
- `app/javascript/game/projectiles.js` — `spec.gravity_scale`, `spec.acceleration`,
  `spec.max_speed` become `spec.flight.*`.
- `app/javascript/game/engine.js` — the four `spec.blast_radius` reads become
  `spec.explosion.radius`.

## Out of scope

- Blast occlusion by walls and cover.
- Explosions damaging other players' vehicles over the network; the relay is scaffolded
  and does not replicate projectile state.
- Reworking the launch angle. The first arc is short at the current 12°; if it wants a
  more pronounced lob that is a one-number follow-up once it can be seen.
- Any change to the monster truck, which carries no launcher.
