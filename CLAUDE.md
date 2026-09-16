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
- Worlds are rows. Four are seeded — `flat`, `targets`, `street` and `hills`; `/?world=<slug>` picks one.
- Buildings generate from a ~300 byte recipe into surfaces, and come apart by the cell:
  glass shatters, timber splinters, brick spalls, and a storey that loses what holds it
  up brings down everything above it — as solid pieces that fall and land, rather than
  as a building that vanishes.
- `street` is twelve of them, six a side down a road, varied by footprint, storeys, roof
  and seed. It exists because every claim the building code makes about SCALE — one draw
  call per material across all buildings, one shared spatial grid, one shared pool of
  falling slabs, collapses that stay independent — was asserted for years against a world
  containing exactly one house, where the shared thing and the per-building thing are the
  same thing. Twelve houses is 6692 pieces in 103 KB of spec and **thirty-two draw calls,
  fewer than the one-house world's thirty-four**. It is deliberately not a city: past
  roughly a hundred buildings the inline spec and the up-front `InstancedMesh` allocation
  both want streaming, which is its own design.
- `hills` is the first world whose ground is not a slab: four 200 m heightfield tiles
  meeting at the spawn, generated at fixture load from `Game::Terrain::Hills`, fetched by
  the client over `/worlds/:slug/:digest/tiles/:tx/:tz` and stood on as Rapier
  heightfields. One house stands on its slope. The other three worlds stay flat on
  purpose: their timing assertions are calibrated on flat ground.

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

Useful URLs while the server is up: `/?world=<slug>` picks the world (`flat`, `targets`, `street`, `hills`),
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
| `Game::Terrain::Sampler` / `Tile.interpolate` | `game/world/terrain.js` (`Terrain#heightAt`) |

The Ruby side has unit tests under `test/models/game/`. `test/system/parity_test.rb` hands
both sides of every pair the same cases — plus `Game::Explosion`'s curves — and holds them
to the same answers; `game/parity.js` is the JS end of that and is used by nothing else.

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

### A condemned house falls as slabs (`game/world/falling_pieces.js`, `chunking.js`)

A collapse used to replace a house with a cloud of shards between one frame and the next, which
reads as the building being deleted rather than as it falling down. Now the cells still standing
are covered with rectangles by `tileSurface`, and each rectangle falls as ONE dynamic body which
tumbles and throws the shards it used to throw **at the moment it lands**.

Everything else about being condemned still happens in the frame it is decided — state, blast grid
and collider all go at once, because structurally the cell *is* gone. Only its appearance is
deferred, and only to the slab carrying it.

**The grouping is the whole point, and it is not `Game::Building::Blocks`.** Blocks decide what
breaks *together when hit*, so they are small and ragged on purpose. Measured on the targets house:
299 blocks over 690 cells, and floor and roof surfaces carry no blocks at all — 764 of its 1398
cells are their own piece. Falling by block is 1063 units, a coarsening of 1.32, which is confetti
with extra steps. 3×4 rectangles reach 356 units, and a wall is three rows tall, so a slab is a
storey-high wall section rather than a metre cube. Going coarser stops paying: 4×6 saves another
49, because walls fragment around their windows whatever the cap.

**The budget is measured, not guessed, and it is TWO numbers.** `per_building` is what one
collapse may put up — the stride budget, how coarsely one house comes apart. `max` is the global
ceiling on live bodies, which is a physics cost and nothing to do with any one building. While one
house existed anywhere the two were indistinguishable, and that is exactly how they came to be
conflated: `capacity` returned the ceiling whole, so a second collapse read the whole budget as
free while the first house's slabs were still in the air, dropped its full complement on top, and
left the pool to make room by taking the OLDEST slabs back — out of the building that was still
falling. They shattered in the sky and reported home that they had landed, which revealed that
house's rubble early, under a house that had not finished coming down. Nothing downstream looks
wrong when this happens, which is why it needed asserting rather than watching: measured on the
street, seven houses condemned together promised 1325 slabs against a ceiling of 1200.

So a collapse asks `budgetForCollapse()` — its own allowance, clamped by what is actually free —
and `drop` returns false when the world is full rather than making room. Full means no, never
"make room"; what does not fit breaks where it stands, which is what everything did before slabs
existed. Measured on the headless software renderer the suite runs on, sampling `world.step`
against what was in the air: about a thousand slabs costs 0.571ms mean / 1.1ms worst, ~7% of a
120Hz frame, which squares with the 6% the old value of 600 was measured at; 1200 costs 1.2ms
mean. So `max` is 1200 and `per_building` is 450 — three of the largest houses on the street at
once, or six ordinary ones, each falling in full. The largest tiles to 397 slabs and the targets
house to ~356, so the stride that thins a collapse is a cathedral's problem, not a house's.

Two more things hold it up, both commented at their sites:

- **Falling slabs are deaf to each other** (`FALLING_GROUPS` excludes its own layer). Condemned
  panels start out flush with the panels beside them; if they could touch each other the whole
  storey would burst on its first frame and nothing would ever be seen to fall.
- **Silent restores drop nothing.** `applyState` passes `silent`, and a ruin arrived at is a ruin —
  raining masonry on every page load is the same lie as re-staging its shards.

**Nothing here crosses the wire.** A cell is still broken, numbered and reported individually; a
slab is only how the fall is drawn and simulated, so the server has no idea slabs exist. `chunking.js`
is JS-only for that reason — it is not part of the piece-index arithmetic that `Surface`'s parity
contract covers.

This is the one place in the building code holding genuine Rapier body lifetimes, so the footgun
below is live here in a way it is not for a standing piece.

### What is left on the ground (`game/building/rubble.rb`, `world/rubble.js`, `render/remnants.js`)

A collapsed building leaves a low pile of wreckage that is solid, has to be cleared, sits in
the same place for every player, and is visibly made of what the building was made of.
**Rubble is not a new kind of object** — it cannot be, because `world_objects` belong to a
*world* while `object_damages` belong to a *(match, object)* pair, so a rubble row created
by a collapse in one match would exist in every match, including the ones where that house
is still standing.

Instead a building reserves piece indices for the wreckage it will eventually leave, carried
by one extra `Surface` of `kind: :rubble` **appended last** — the same idea as a doorway
being a real index holding `void`, extended to indices reserved for something that arrives
later rather than never. Every requirement then rides machinery that already exists:
positions derive from the recipe seed, clearing goes through `damage`/`breaks` addressed by
`[object_id, piece_index]`, persistence is a bit in `broken_pieces`, and rejoining is
`request_state`. No new message, no new table, no new column.

- **A heap is ONE piece drawn as a lump and its chunks.** One index, one collider, one entry
  in the state arrays — and on screen a base lump of dust in the `rubble` material's grey
  with `rules.collapse.rubble.fragments` chunks of brick, timber, tile, glass and plaster
  in and on it. Ruby ships **`mix`** on the rubble surface (each material's share of the
  building's volume, largest first, from the surfaces the generator built) and a **`chunk`**
  profile per material (size on each axis, variation, how far off a box); the client derives
  every chunk's material, position, size and lean from those and the seed through
  `heapFrame`/`heapFragments`, and `Math.random` appears nowhere. Chunks are instances in
  per-material pools named `brick#rubble`, `timber#rubble`, … — the suffix picks a shape,
  never a material, as `rubble#3` does. `Building.countMaterials` sizes those pools by
  running the same seeded material draw the builder runs, because an `InstancedMesh`
  cannot grow.
- **A heap is placed in WORLD space.** The rubble grid's normal is `u × v = (0, -1, 0)` — it
  points **down** — and lifting or flattening a heap along the surface's own axes came out
  inverted twice. So `heapFrame` works in world terms from the start (a centre on the
  ground, a yaw, two half-extents, a height) and `heapMatrix` carries the lump's local z
  onto world up before the yaw. The lump is level; the lean is on the chunks. The collider
  is sized from the level lump, because forty leaned boxes are forty invisible ramps.
- **The lump is a mound, not a solid.** `lumpGeometry` used to be an icosahedron squashed
  and normalised to fill its box; normalised to a box a metre and a half tall that has
  near-vertical flanks and facets the size of a door, and a row of them along the edge of
  the pile lined up into a faceted wall — the "flat sides" seen from the road, whatever the
  pile's overall profile was. It is now a rounded cone (`1 - r^MOUND_PROFILE`) built in
  rings with a lobed outline and brick-sized facets, no underside, still normalised to fill
  its box. The chunks are seated on that same slope.
- **The truck goes THROUGH wreckage, not over it, and that is a collision-group rule.** The
  wheels are raycasts, so anything they land on is ground: with heaps in their filter the
  truck rode up the rim, its blade never reached a heap, and it stalled on top of the mound
  having cleared nothing (measured). Heaps therefore live on `LAYER.RUBBLE`, and the wheel
  rays use `WHEEL_RAY_GROUPS`, which excludes it. The chassis and the blade still meet
  heaps as solid boxes, break them, and `punchThrough` gives back the speed they were not
  worth — scaled by the material's **`toll`** (0.15 for rubble, 1.0 for everything solid),
  because a blade hit clears a plus of five heaps and at a wall's toll that stalled the
  truck two thirds of the way across. Measured after: in at 13.7 m/s, never below 12 across
  the pile, nineteen heaps cleared.
- **The pile is the size of the house, and its height is a picture rather than an
  obstacle.** Because the wheel rays pass through heaps and the blade breaks whatever it
  meets, how tall the pile stands no longer decides whether the truck gets through, so
  `SHARE` is free to say what a fallen house looks like: 1.0, all of the bulked volume,
  which on the worked example averages about 1.8 m over the ground the wreckage covers and
  mounds to some three metres in the middle with shoulders a metre tall most of the way
  out. At 0.25 it peaked at 1.75 m, which was a pile for a bungalow under a
  twelve-metre ridge. The dome's `falloff` is 1.6 and volume conserving (normalised by its
  own mean over the heaps), so the material Ruby derived is neither created nor destroyed,
  only mounded.
- **The wreckage skirts the walls, raggedly.** `Rubble::MARGIN` (3 m) grows the grid past
  the footprint's bounding box on every side, centred in whole cells, and a cell holds a
  heap when its centre is inside the footprint or within that cell's own **reach** of one of
  its edges (`covered?`). The reach is drawn per cell from the seed between
  `REACH_FLOOR × MARGIN` and `MARGIN`, so the first metre beyond the walls is always covered
  and the far cells thin out — which is what stops the pile's outline being the grid's own
  rectangle. An L-shaped house skirts its notch as well as its outside, and nothing lands
  on the road. The depth is the kept volume over the ground the heaps actually cover, not
  over the footprint. **Changing `MARGIN`, `REACH_FLOOR` or `CELL` changes `piece_count`
  for every building** — the fixtures carry the counts by hand and `world_summary_test`
  checks them. Fix the dev database by updating `piece_count` **in place** from
  `surface_set.piece_count`; a reseed replaces every world row, hand-made ones included,
  and orphans the matches played on them.
- **The profile is a rounded cone, `1 - d^falloff`, lopsided.** A straight `(1 - d)` power
  made a triangle; a cosine bell trailed off into a flat mat on every side, which read as
  flat edges. The rounded cone keeps its bulk toward the rim and then drops. Its centre is
  pushed off the middle by `offset` and its radius wobbles in two or three seeded lobes
  (`lobe`), so the mound is a lopsided blob rather than an ellipse over the house; and the
  fringe shrinks in plan with its height (`rim`), so the edge is scattered small mounds
  rather than a ring of plates. Still normalised by its own mean over the heaps, so the
  volume is conserved. The reveal ORDER still uses the plain radius: the shape is a picture,
  the order is a contract with the server.
- **Heaps arrive as the pieces carrying them land**, not when the collapse is decided, and
  each one **rises out of the ground** over `rules.collapse.rubble.rise` (the collider is
  enabled at once; only the drawing eases, from `Building#update`). A collapse works out
  how much wreckage it owes (`expectRubble`) and reveals none of it; each falling slab
  reports home when it shatters and the building reveals its share. A restore reveals
  everything at once and silently.
- **Clearing a heap leaves a few of its chunks lying.** `breakCell` on a heap that was
  actually standing hands `remnants.keep` of its chunks to `Remnants` — plain meshes with a
  material each, because fading is a per-piece opacity — which **settle** onto the ground,
  **linger**, then **fade while sinking**; `shards` more are thrown through `Debris` in their
  own materials. Remnants are local and capped; a silent restore leaves none.
- **The small stuff is swept by hand, because it has no bodies.** Shards and remnants are
  never in Rapier, so a car reaching them is not a collision: once per car per step the
  engine builds the car's box plus `rules.debris.reach` (ours and every remote's) and
  `Buildings#sweepVehicle` kicks whatever is inside it away from the car, carried with it
  and lifted, with `kicked_life` left; `BlastWave` does the same to the band its shell
  just grew through. Fresh debris is left alone for `grace`: the shards a blast throws are
  born inside its own shell, and the remnants a ploughing truck leaves are born inside its
  box, and both used to be swept by the thing that made them. `__arenaDebrisKicked` counts
  kicks; `__arenaDebrisKickedLive` reads zero once the kicked debris is gone.
- **Heaps are revealed outward from the middle**, and the ORDER is shared with the server
  rather than merely the count. `Building::Rubble.pile_indices` and `pileOrder` must return
  the same sequence, because the server gates damage on the revealed prefix. Both sort by a
  quantised radius with the index as tie-break.
- **No heap may be too small to reach its neighbour.** Heaps sit `CELL` apart and are
  `CELL * SPREAD` across; `spread` and `aspect` can both shrink one below the spacing, and
  `spec_test` asserts the invariant over BOTH. `DENSITY` is 1.0 because an empty cell is a
  hole by construction. `edge` must never be zero — a heap of no height is an invisible
  piece with a degenerate collider.
- **Piece state gained a third value.** `DORMANT → INTACT → BROKEN` is strictly monotone.
  Revealing moves `DORMANT → INTACT` and **never** `BROKEN → INTACT`; and `breakCell` treats
  `DORMANT` as **breakable rather than already broken**, because `applyState` applies the
  broken bitset *before* it reveals anything.
- **A collapse must never sweep its own rubble** — silent and permanent if it did. Three
  independent defences: `storey: -1`, an explicit `kind == :rubble` skip in `each_cell`, and
  `structural_weight: 0.0` on the material.
- **The grid is geometry, not tuning.** `Rubble::CELL`, `DENSITY`, `SPREAD`, `BULK` and
  `SHARE` are Ruby constants: the first two decide `piece_count`, and the rest decide a
  heap's depth, which `health_for` is computed from on both sides. `rules.collapse.rubble`
  ships only how a heap is *drawn*, and `scale` and `shapes` are read from the constants.
- **`piece_count` grows, so a stale database is a real failure mode.** Rubble was appended
  and nothing renumbered, but a row holding an old count rejects every rubble index. After
  pulling a change to the grid, reseed or update `piece_count` from `surface_set.piece_count`.
  The worked example went 1454 → 1502 when rubble arrived, 1502 → 1534 when it grew a
  margin and 1534 → 1553 when the margin grew and went ragged; the street's twelve moved
  with it each time.

### Terrain (`game/world/terrain.js`, `physics/terrain.js`, `render/terrain_view.js`)

The ground of a world with `terrain_tiles` is a heightfield. Ruby's half —
`Game::Terrain::{Frame, Tile, HeightsCodec, Sampler, TileBuilder, Manifest}` — encodes int16
centimetres, rows north→south and columns west→east, and ships a manifest in
`arena.terrain` (`null` for a flat world) with one **digested URL per tile**. The digest is
the tile's own bytes, so the URL is exactly as immutable as the response says it is
(`public, immutable, max-age` of a year). The client fetches every tile before boot,
decodes each to one `Float32Array`, and builds the collider, the mesh and the sampler from
that same array.

- **Never use `PlaneGeometry` for terrain.** Rapier's heightfield is column-major and
  splits every cell on the **anti**-diagonal (measured against the vendored build with a
  Node spike, not read off docs); `PlaneGeometry` splits the other way, and the
  disagreement is silent — the car rests above or sinks into ground that is not where it
  is drawn. `terrainIndexBuffer` and `terrainVertex` are the two places the convention
  lives, `physicsHeights` is the one transpose, and `__arenaTerrainProbe` proves the three
  agree at runtime: `terrain_test.rb` surveys both triangles of every cell and both seams
  and asserts `|physics − render| < 1e-3`, and also that the *other* diagonal would have
  differed, so the survey is known to have teeth.
- **A vertical ray exactly on a grid line can miss.** Measured on `hills`: a ray straight
  down on 28 of the 79 row lines, or 28 of the 79 column lines, gets no hit from Rapier
  anywhere along that line, while a centimetre off it hits — float32 rounding of the cell
  index in parry's vertical-ray special case. A measure-zero quirk, not a height
  disagreement; the survey keeps its seam probes a quarter metre off the perpendicular
  lines, and a moving car's wheel rays are neither exactly vertical nor exactly on a line.
- **Interpolation is the triangle, never bilinear**, in both languages
  (`Tile.interpolate` ↔ `interpolate`). Bilinear is 80 cm off where terrain steps across a
  cell; that is how props float.
- **Everything that lies on the ground asks `ground(x, z)`** — rubble's `heapFrame`,
  shards, remnants, the chase camera. It is `null` on a flat world and every taker
  reproduces its old behaviour exactly when it is; the three flat worlds are bit-identical.
- **Spawns and buildings carry their own `y`.** The hills fixture computes them from the
  function; a house on a slope stands at the mean height under its corners, buried a little
  uphill and clear a little downhill. That is a seeder concern, never a recipe field.
- **The bounds walls reach 10 m below the lowest ground** (`min_cm` over the tiles), or the
  valley under a wall standing on zero is open air.
- **Nothing crosses the wire.** The server never samples terrain during play; `Sampler`
  exists for tests and, later, the seeder.

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

And one that is not a lifetime rule but is found the same way, by something quietly never happening:

- **Rapier reports a contact STARTING, not a contact continuing.** A body created already resting
  against something gets exactly one collision event, on its first frame, and no second one is
  ever coming, because it never stops touching what it sits on. `FallingPieces` discarded that
  event as arriving too early to act on, and twenty-two of a hundred and thirty-two pieces hung
  motionless for the full backstop and vanished together. Remember the touch and act on it later;
  never drop it.

`GameEngine#dispose()` frees the event queue, world, renderer context and audio graph explicitly.

### Input

Keyboard, pointer and gamepad sources each write into one normalised `InputState`
(`game/input/`). Bindings are data from `Game::InputBindings`, which also drives the on-screen
controls panel — so the panel can never drift from the bindings it documents. Keyboard entries are
`KeyboardEvent.code` values.

### Multiplayer

`ArenaChannel` has two halves with deliberately opposite rules.

**Vehicles are relayed and never simulated.** Each client authoritatively simulates its own
car; the server stamps `player_id` from the session cookie (`ApplicationCable::Connection`)
and fans out. Simulating would cap feel at the network tick rate. Every module under
`game/net/` is imported now.

Two things about remote cars that are not obvious:

- **Leaving cannot be announced.** A browser closing a tab does not reliably get to run
  JavaScript on the way out, so the unsubscribe never reaches the server and it falls back
  to noticing a dead socket — measured at **12.5 seconds**. So silence is what counts as
  gone: a remote unheard from for `rules.remote_timeout` is dropped. The channel's `leave`
  message is honoured when it arrives, but it is the fast path, not the mechanism.
- **One browser is one player.** `player_id` comes from the session cookie, so two tabs
  share it and each correctly discards the other's snapshots as its own echo. Testing
  multiplayer needs two Capybara sessions (`Capybara.using_session`), not two tabs — and
  the backgrounded one has its `requestAnimationFrame` throttled, so it sends far fewer
  snapshots than it would in front of a player.

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

Every system test says which world it needs — `visit_world("flat")`, `visit_world("targets")`,
`visit_world("street")`, `visit_world("hills")`.
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
| `__arenaPieceMatrix` | A piece's world transform, so a test can prove two clients agree on where it is |
| `__arenaRubble` | `{ dormant, standing, cleared }` heaps — an intact house has only the first |
| `__arenaHeapFragments` | `(piece, buildingId)` — the materials of one heap's chunks, one entry per chunk. "The wreckage is made of what the house was made of" is an assertion about this |
| `__arenaRemnants` | Chunks left lying by cleared heaps and still visible — positive the moment a heap clears, zero once they have faded |
| `__arenaDebrisKicked`, `__arenaDebrisKickedLive` | Shards and remnants kicked out of a car's or a blast's way, cumulatively, and how many of those are still visible |
| `__arenaFalling` | How many falling slabs are in the air — zero at rest, which is what makes a fall assertable |
| `__arenaFallingCells` | How many cells those slabs carry. Against `__arenaFalling` it says how much of the house left the ground, and how coarsely |
| `__arenaSlabsDropped` | `(buildingId)` — how many slabs THAT building put up, as against how many are up altogether. The two are the same number while one house exists, which is how the shared budget was over-subscribed in silence |
| `__arenaBuildingStanding` | `(buildingId)` — one building's standing pieces. Moves both ways: a piece breaking takes it down, a heap of rubble being revealed puts it up, so "exactly unchanged" is what proves a neighbour was untouched |
| `__arenaDraws` | `renderer.info.render.calls` — turns "did the render plan regress" into an assertion |
| `__arenaQuality` | Which tier the engine actually settled on |
| `__arenaDebugVisible`, `__arenaMasterGain` | Overlay / audio assertions |
| `__arenaTerrainProbe` | `(x, z)` — `{ physics, render, sampled, other, delta }`: a downward raycast against the heightfield, barycentric interpolation over the drawn triangles, the client sampler, and what the *opposite* diagonal would say |
| `__arenaTerrainHeight` | `(x, z)` — `Terrain#heightAt`, the ported sampler; `null` on a flat world |
| `__arenaHeapGround` | `(piece, buildingId)` — `{ x, z, ground }`: where a heap was put down and the ground it was put on |
| `__arenaParity` | `{ turboBar, damage, explosion, surface, terrain }` — the JS side of every ported pair, fed cases by `parity_test.rb` |

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
