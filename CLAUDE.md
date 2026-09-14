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
- Worlds are rows. Two are seeded, `flat` and `targets`; `/?world=<slug>` picks one.
- Buildings generate from a ~300 byte recipe into surfaces, and come apart by the cell:
  glass shatters, timber splinters, brick spalls, and a storey that loses what holds it
  up brings down everything above it.

## Commands

```bash
bin/setup                  # install, prepare db, start server
bin/dev                    # rails server
bin/ci                     # full CI: rubocop, bundler-audit, importmap audit, brakeman, tests
bin/rubocop                # rails-omakase style

bin/rails test                                   # model/channel tests only (system tests excluded)
bin/rails test test/models/game/spec_test.rb     # one file
bin/rails test test/models/game/spec_test.rb:24  # one test by line
bin/rails test:system                            # browser tests — headless Chrome, slow, serial
bin/rails test test/system/driving_test.rb       # one system test file
```

`bin/ci` deliberately leaves system tests out (they need Chrome and take minutes). Run them
by hand after touching anything in `app/javascript/game/`.

Useful URLs while the server is up: `/?world=<slug>` picks the world (`flat`, `targets`),
`/?vehicle=buggy` picks the vehicle, `/?quality=low` drops shadows and pixel ratio, `/?match=<name>`
picks the ActionCable match. In-game: `G` toggles the debug overlay, `V` switches vehicle,
`R` respawns, `H` hides the controls panel, `M` mutes.

`bin/dev` resolves its own port: an explicit `PORT`/`-p` wins, else the port recorded in
`.dev-port`, else the first free one in the 31xx band, which it then records. Several worktrees
run servers on this machine at once and 3000/3001 are taken by other apps.

## Architecture

### Active Record at the top level, plain Ruby under `game/`

`app/models/*.rb` are Active Record: `World`, `TerrainTile`, `WorldObject`, `Match`,
`ObjectDamage` — whose bitset column is `broken_pieces`, not `destroyed`, because `destroyed`
collides with Active Record's own `destroyed?` and the collision is fatal: defining the
attribute raises and the model cannot be instantiated at all. `app/models/game/**` are plain Ruby objects that **never touch the database** —
they are handed what they need and return value objects. A `World` builds a `Game::Scene`; a
`Game::Scene` never looks a `World` up. That split is what keeps almost all of the game's
logic testable without fixtures, and it is worth preserving.

Note the naming trap: `Game::World` no longer exists, and must not come back. Inside
`module Game` a bare `World` resolves to `Game::World`, so a PORO by that name sitting
beside the `::World` record would be a bug with a very long fuse. The composition root is
`Game::Spec`.

### Ruby owns the rules, the browser runs the simulation

`Game::Spec.for(world)` composes the world's scene, both vehicles, the material table, the rules
hash and the input bindings, and `#to_spec` serialises the lot into a
`<script type="application/json">` tag in `app/views/arenas/show.html.erb`. `arena_controller.js`
parses it and hands it to `GameEngine`.

**Every tuning number lives in Ruby.** The JS side holds no constants of its own — chassis, engine,
suspension, drift, turbo, camera, audio, part damage profiles, and every number in
`Game::Materials` all arrive in the spec. Retuning feel means editing
`app/models/game/vehicles/*.rb` or `materials.rb`, never JavaScript. `Spec#to_spec` appends a SHA
digest as `version` so two clients on different tuning are detectable rather than silently
desyncing.

A few behaviours are *ported* rather than shipped as data, because they must run every frame
client-side. These pairs must be changed together:

| Ruby | JavaScript |
|---|---|
| `Game::TurboBar` | `game/turbo_bar.js` |
| `Game::DamageResolver` + `Part#armed?` | `game/damage.js` |
| `Game::Building::Surface` (the grid) | `game/world/surface.js` |

The Ruby side has unit tests under `test/models/game/`; the JS side is only covered indirectly by
the browser tests. (Comments in those JS files mention a "parity system test" — no such test
exists yet.)

**`Game::Damage::Collapse` is deliberately NOT ported**, and the file opens with the reasoning
because the temptation to port it will recur. An individual break is monotone and self-caused, so
a client can predict it and never have to undo one. A collapse is neither: it follows from the sum
of what every player has done to a building, and it is the one event that cannot be walked back.
The server decides and says so in `[object_id, from_storey]`; the client expands that against
surfaces it already holds.

### Buildings: recipe → surfaces → pieces

A `world_objects.recipe` is a few hundred bytes — footprint ring, storeys, eaves, ridge, roof type,
cell size, seed. `Game::Building::Generator` turns it into a `SurfaceSet` deterministically and on
demand; **pieces are never rows and are never materialised on the server**. That is the only reason
a thousand buildings can be a thousand rows rather than a quarter of a million.

A surface is a regular grid of cells with a `piece_offset`, and the client expands it. Two rules
hold the whole thing together, and both are commented at their sites:

- **Piece index space is never culled, only geometry is.** `piece_index = off + row * cols + col`
  for every row and column, always. A doorway is a real index holding `void`; a gable's clipped
  corners are real indices holding `void`. If either side culled, both would have to cull
  identically forever, and the first divergence would silently renumber every piece after it.
- **Generation order is part of the contract.** Offsets are handed out by walking the surfaces in
  sequence, so reordering `Walls → Interior → Roof` renumbers everything after the change — damage
  recorded against a wall would come back applied to the roof. The worked example in
  `generator_test.rb` pins the order, the offsets and the piece count.

Cells are tiled into polyomino **blocks** (`Game::Building::Blocks`) that break together, so holes
come out ragged rather than as clean rectangles. `Game::Materials` is the frozen table every
destructible thing behaves by; `void` is a real entry with zero everything, which is what keeps
the index arithmetic uniform.

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

### Multiplayer — destruction is wired, vehicles are not

`ArenaChannel` now has two halves with deliberately opposite rules.

**Vehicles are relayed and never simulated.** Each client authoritatively simulates its own
car; the server stamps `player_id` from the session cookie (`ApplicationCable::Connection`)
and fans out. Simulating would cap feel at the network tick rate.
`game/net/{snapshot,remote_vehicle}.js` still exist and **nothing imports them** — remote
vehicles are the open piece of work. `net/connection.js` is imported now.

**Destruction is the other way round: the server decides.** A client predicts its own
breaks — it must, or driving through a wall would bounce you off while a round trip
completed — but what is actually gone is the server's call, because a collapse follows from
the sum of what every player has done to a building and no client can see that sum.

```
client  damage {seq, hits: [[object_id, piece_index, raw, kind], …]}   batched at snapshot_hz
        request_state {ids}                                            on every connect
server  breaks {broken, collapses, authority}                          broadcast
        state  {objects, authority}                                    to the asker alone
        error  {reason}                                                to the asker alone
```

Four rules hold it together:

- **Everything is monotone.** A piece goes standing → broken and never back; `collapsed_from`
  goes NULL → lower and is never raised. So every message is idempotent, a self-predicted
  break is always confirmed, and a client that already broke a piece ignores any `state`
  saying it stands — which is what makes a rollback after a restart invisible.
- **`breaks` is broadcast without a `player_id`.** Every other broadcast is stamped, and
  `NetConnection` drops its own echo — but the client that knocked the walls out is exactly
  the one that most needs to hear the house came down.
- **Clients report RAW damage per cell**, after their own spread and block expansion, before
  absorb. The server runs the same absorb from the same table. Sending the absorbed figure
  would apply the material twice; sending only the cell that was touched would mean porting
  spread and block tiling to the server.
- **Reporting lives in `damageCell`, never `breakCell`.** `breakCell` is also how a
  server-applied break lands, so reporting there would echo every broadcast back at the server.

**Destruction is authoritative in exactly one process.** `config/puma.rb` has no `workers`
line, so that is true by construction; `ArenaChannel::AUTHORITY` and `Match#claim` make it
*enforced*. A process that loses the claim refuses `damage` and replies
`error: "not_authoritative"`, so destruction degrades to nothing rather than diverging
silently. `Game::Damage::Registry` is process-global, holds one `MatchState` per match behind
its own `Monitor`, and a single sweeper thread flushes dirty matches to `object_damages` every
second. That sweeper does **not** run under test — the suite calls `Registry.flush_all!` when
it wants rows, and `Registry.reset!` in teardown, because the registry is memory and no test
transaction rolls it back.

Caps (`MAX_HITS_PER_BATCH`, `MAX_AMOUNT_PER_HIT`) bound what one bad client can reach. They
are **not security** — the server cannot recompute damage without simulating, which is the
accepted price of clients reporting it.

Any system test that breaks something must pass `visit_world(..., match: "its-own-name")`.
Damage persists, so two tests sharing the default lobby share their wreckage.

## Testing

**Don't run the suite between tuning steps.** When something is being adjusted for *feel* —
damage numbers, handling, how a building comes apart — the full system suite takes ~7 minutes
and tells you nothing about whether the change feels right. Run the one file that covers what
changed, or nothing at all, and let the person driving the game say whether it is better. Save
the full run for when the change has settled. The same goes for re-running a whole suite to
chase one failure: run that file.

Every system test says which world it needs — `visit_world("flat")`, `visit_world("targets")`.
The worlds are defined once in `test/fixtures` and loaded from there by `db/seeds.rb`, so a test
and the browser cannot disagree about what is standing where. The suite runs at `quality: "low"`,
which drops shadows and pixel ratio; that is the tier the timing assertions are calibrated on.

Model/channel tests are ordinary and fast. System tests drive real headless Chrome with
SwiftShader (no GPU) and assert on physics outcomes — how far the car travelled in two seconds,
whether the bull bar only bites mid-drift. They run **serially** (`parallelize(workers: 1)`):
competing Chrome instances starve the render loop and turn timing measurements into noise.
That also holds across worktrees, so the suite takes a machine-wide lock; expect it to block
rather than fail when another checkout is running it. A dev server in the same worktree skews
the timings too, and the suite warns when it finds one.

System tests that drive at a target need **margin**: the monster truck covers about 15m in the
2.5s these tests usually drive for, so a 14m run-up arrives exactly as the clock runs out and
fails as "the hit did not register" rather than "the car never got there". Prefer the piece
hooks (`__arenaBreak`, `__arenaDamagePiece`) over aiming a car at something whenever the
assertion is not actually about driving.

The engine exposes debug/test hooks on `window`:

| Hook | Purpose |
|---|---|
| `__arena` | Live telemetry object — speed, grounded wheels, drift state, damage, everything |
| `__arenaInput` | Assign an object to drive the vehicle directly, bypassing synthetic-key jitter |
| `__arenaPlace` | `{x, y, z, yaw}` — park the vehicle at a known pose |
| `__arenaFlip` | Drop it in upside down to exercise flip recovery |
| `__arenaBreak`, `__arenaRestore` | `(piece, buildingId)` — break or restore one piece outright |
| `__arenaDamagePiece` | `(piece, amount, buildingId)` — damage without driving into anything |
| `__arenaPieceState`, `__arenaPieceBlock` | What a piece is made of, how hurt it is, which block it breaks with |
| `__arenaDraws` | `renderer.info.render.calls` — turns "did the render plan regress" into an assertion |
| `__arenaQuality` | Which tier the engine actually settled on |
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
