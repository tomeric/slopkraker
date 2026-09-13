# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Rails 8.1 app whose only page (`root` → `arenas#show`) is a browser based multiplayer vehicle
destruction game. The goal is for a 3d representation of a city with fully destructible environment.

We use three.js for rendering, Rapier (wasm) for physics, both vendored and served over importmap.

Two vehicles:
- Monster Truck with Jump Jets + ground slam, and a Bulldozer blade
- Fast Buggy with a Rocket Launcher, and a rear-mounted Bull Bar to destroy stuff while drifting.

Currently:
- Drive around a walled arena with ramps, a circuit and destructible crates/pillars.
- Everything under `app/models/game/` is a plain Ruby object for now.

## Commands

```bash
bin/setup                  # install, prepare db, start server
bin/dev                    # rails server
bin/ci                     # full CI: rubocop, bundler-audit, importmap audit, brakeman, tests
bin/rubocop                # rails-omakase style

bin/rails test                                   # model/channel tests only (system tests excluded)
bin/rails test test/models/game/world_test.rb    # one file
bin/rails test test/models/game/world_test.rb:24 # one test by line
bin/rails test:system                            # browser tests — headless Chrome, slow, serial
bin/rails test test/system/driving_test.rb       # one system test file
```

`bin/ci` deliberately leaves system tests out (they need Chrome and take minutes). Run them
by hand after touching anything in `app/javascript/game/`.

Useful URLs while the server is up: `/?vehicle=buggy` picks the vehicle, `/?match=<name>` picks
the ActionCable match. In-game: `G` toggles the debug overlay, `V` switches vehicle, `R` respawns,
`H` hides the controls panel, `M` mutes.

## Architecture

### Ruby owns the rules, the browser runs the simulation

`Game::World.build` composes the arena, both vehicles, the rules hash and the input bindings, and
`#to_spec` serialises the lot (~100KB) into a `<script type="application/json">` tag in
`app/views/arenas/show.html.erb`. `arena_controller.js` parses it and hands it to `GameEngine`.

**Every tuning number lives in Ruby.** The JS side holds no constants of its own — chassis, engine,
suspension, drift, turbo, camera, audio, part damage profiles all arrive in the spec. Retuning feel
means editing `app/models/game/vehicles/*.rb`, never JavaScript. `World#to_spec` appends a SHA
digest as `version` so two clients on different tuning are detectable rather than silently desyncing.

A few behaviours are *ported* rather than shipped as data, because they must run every frame
client-side: `Game::TurboBar` → `game/turbo_bar.js`, `Game::DamageResolver` + `Part#armed?` →
`game/damage.js`. These pairs must be changed together. The Ruby side has unit tests under
`test/models/game/`; the JS side is only covered indirectly by the browser tests. (Comments in
those JS files mention a "parity system test" — no such test exists yet.)

### The engine loop (`app/javascript/game/engine.js`)

Fixed-step accumulator at `rules.physics_hz` (120Hz), capped at `max_substeps`, with render
interpolation between the last two physics states — so a 60Hz display stays smooth. Input is
sampled **once per frame**, so every substep in that frame sees identical input. Wheels are the
exception to interpolation: they're read live, because suspension travel and steer angle are
what the player reads as responsiveness.

Pipeline per step: `vehicle.update` → capture pre-step velocity → `world.step` → drain contact
events → projectiles → destruction → read back transforms.

Impact speed is captured **before** the solver runs. Contact events are reported after the step,
by which point the car and what it hit have been pushed toward a shared velocity, which reports a
real impact as a nudge.

### Rapier wasm lifetimes — the recurring footgun

Rapier bodies live on the wasm heap and are not GC-reachable. Two rules that have already caused
bugs, both commented at their sites:

- Never create or remove a body inside a `drainCollisionEvents` / `drainContactForceEvents`
  callback — Rapier borrows the world mutably for the duration and Rust's aliasing check trips.
  Collect impacts into a list, apply them after the drain.
- Once a prop breaks its body is freed; touching it afterwards (reading `translation()`, leaving
  it in the interpolation list) reads released memory and poisons the whole Rapier instance.
  Read positions before applying fatal damage; `untrack()` the body on break.

`GameEngine#dispose()` frees the event queue, world, renderer context and audio graph explicitly.

### Input

Keyboard, pointer and gamepad sources each write into one normalised `InputState`
(`game/input/`). Bindings are data from `Game::InputBindings`, which also drives the on-screen
controls panel — so the panel can never drift from the bindings it documents. Keyboard entries are
`KeyboardEvent.code` values.

### Multiplayer — scaffolded, not wired up

`ArenaChannel` relays snapshots between clients; the server stamps `player_id` from the session
cookie (`ApplicationCable::Connection`) and never simulates. `game/net/{connection,snapshot,remote_vehicle}.js`
exist and are tested on the Ruby side, but **nothing imports them** — `engine.js` has no net layer
yet. Wiring them in is the open piece of work.

## Testing

Model/channel tests are ordinary and fast. System tests drive real headless Chrome with
SwiftShader (no GPU) and assert on physics outcomes — how far the car travelled in two seconds,
whether the bull bar only bites mid-drift. They run **serially** (`parallelize(workers: 1)`):
competing Chrome instances starve the render loop and turn timing measurements into noise.

The engine exposes debug/test hooks on `window`:

| Hook | Purpose |
|---|---|
| `__arena` | Live telemetry object — speed, grounded wheels, drift state, damage, everything |
| `__arenaInput` | Assign an object to drive the vehicle directly, bypassing synthetic-key jitter |
| `__arenaPlace` | `{x, y, z, yaw}` — park the vehicle at a known pose |
| `__arenaFlip` | Drop it in upside down to exercise flip recovery |
| `__arenaDebugVisible`, `__arenaMasterGain` | Overlay / audio assertions |

Most system tests drive through `__arenaInput`; one test in `driving_test.rb` uses real key events
so the binding layer stays covered. `ApplicationSystemTestCase#wait_for` polls for engine
milestones (Capybara doesn't retry `evaluate_script`) and surfaces SEVERE console errors on
timeout — a silent timeout is almost always a boot exception.

Directional assertions are made against the **camera's** right vector, not a world axis: "right"
only means something relative to what the player sees, and a world-axis assertion happily passes
while steering is mirrored on screen.

## Pinned versions, on purpose

- **three.js 0.170.0**, vendored. 0.178+ splits the ESM build into `three.module.js` +
  `three.core.js`, whose relative import cannot survive Propshaft's production digesting.
- **`json` gem ~> 2.x.** Ruby 4.0 bundles json 3.x, whose `JSON.parse` takes options as keywords
  only; Rails 8.1.3.1 still passes a positional hash, so every encrypted-cookie read raises.
- three.js is imported dynamically in `arena_controller.js` — `controllers/index.js` eager-loads
  every controller on every page, and a top-level import would parse ~4MB app-wide.
