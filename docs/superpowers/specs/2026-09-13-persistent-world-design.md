# A persistent, destructible city in the database

Date: 2026-09-13
Status: partly implemented.

- **Built:** §1 frame, §2 schema, §4 materials, §5 buildings, §9 destruction and debris,
  §10 server-authoritative damage, §11 collapse.
- **Not built:** §3 terrain heightfields, §6 chunk delivery over HTTP, §7 instanced
  rendering and quality tiers beyond the existing `?quality=`, §8 promotion tiers.
- **Revised during implementation:** §11's collapse rule (see the note in that section),
  and §10's `request_state`, which takes object ids rather than `{cx, cz}` because chunk
  streaming does not exist yet. §10's PREDICTED/DENY reconciliation window was deliberately
  not built: nothing in the implementation can deny a break, since the server's rule is
  that any reported damage which would break a piece breaks it, so a self-predicted break
  is always confirmed. That machinery earns its place when the server starts rejecting
  hits, and not before.

## Why

The only world is `Game::Arena`: a 380m walled box with a flat `380×1×380` ground slab,
composed by class methods on every request and inlined as ~100KB of JSON in the page.
Prop health lives in browser memory alone, so a reload restores every crate. There is no
elevation outside the rotated track slabs, nothing has parts, and `db/schema.rb` is still
at version 0.

We want a world that persists, has real elevation, and is made of buildings you can take
apart — brick that spalls, glass that shatters, wood that splinters, a storey that
pancakes when you knock its walls out. Eventually the map comes from the same 3DBAG and
AHN data `~/Developer/mijnstreek` already ingests, and eventually hundreds to thousands
of those buildings are shared and destroyed across a multiplayer match.

That end state is the whole design constraint. A hollow building with storey floors and
interior partitions is ~160 destructible pieces; a thousand of them is ~160,000 pieces.
Pieces cannot be rows, cannot all be colliders, and cannot all be meshes. Everything
below follows from that one number.

## What exists today

- `Game::Arena.build` composes 255 static bodies (ground, 4 walls, 7 ramps, 81 road and
  162 kerb slabs) and 120 props (94 crates, 26 pillars). All literal tables and class
  methods. `Game::Track` (170 lines) is the only source of elevation: a Catmull-Rom
  spline climbing 12m, emitting rotated slabs.
- `Game::StaticBody#to_spec` → `{name, kind, position, size, rotation, colour, friction,
  restitution}`. `Game::DestructibleProp#to_spec` → `{…, mass, health, debris_count}`.
  Box-only. **No material, no shape, no parts, no hierarchy.**
- `Game::DamageResolver.resolve(part:, speed:, state:)` is target-independent — nothing
  about what you hit enters the formula. Ported verbatim to `game/damage.js`.
- `physics/world.js` builds every collider in two one-shot loops. `render/arena_view.js`
  builds a `Mesh` + `BoxGeometry` + `MeshStandardMaterial` per object — ~390 unique
  geometries and materials, no instancing, no merging, no LOD.
- `destruction.js:24-25` mutates `mesh.material.color` per prop to tint damage, which is
  precisely why materials cannot currently be shared.
- `engine.js` (641 lines) keeps a flat `bodies` array walked three times per physics step,
  joins physics to meshes with `getObjectByName`, and `untrack` is a linear `findIndex`.
- `engine.js:418 blastWave()` iterates **every** prop for **every** live explosion on
  **every** 120Hz substep. At 120 props that is fine; in a city it is a hang.
- `ArenaChannel` relays `join`/`leave`/`snapshot` with a server-stamped `player_id` and
  never simulates. No world state is in the protocol at all.
- `physics/groups.js` already has `LAYER.PROP`, `DEBRIS_GROUPS`, and a comment that
  anticipates this work: *"Walls become destructible props in time, at which point the
  PROP bit catches them like anything else."*

## Design

### 1. The coordinate frame

Game units are metres. `x` east, `z` south, `y` up — mijnstreek's convention exactly:

```ruby
to_game(x, y) = [ x - origin_x, -(y - origin_y) ]
```

A `World` row carries `srid`, `origin_x/y/z`, `tile_size`, `height_step` and
`chunk_size`. A synthetic world stores `srid: nil` and a zero origin; an RD import stores
`srid: 28992, origin_x: 185_000.0, origin_y: 330_000.0`. **Importing 3DBAG or AHN is then
a subtraction and nothing else** — no reprojection, no second code path.

`origin_z` is the one field mijnstreek lacks and wants: it keeps absolute elevation
(m NAP) out of the terrain encoding without a per-tile fudge.

`height_step` must divide `tile_size`, or neighbouring tiles disagree along their shared
edge. That is a model validation, not a comment.

### 2. Schema

The app's first migration.

| table | columns |
|---|---|
| `worlds` | `slug`\*, `name`, `srid`, `origin_x/y/z`, `tile_size` (500), `height_step` (5), `chunk_size` (125), `gravity`, `seed`, `bounds`, `spawns`, `content_digest` |
| `terrain_tiles` | `world_id`, `tx`, `tz`\*, `base_cm`, `heights` (blob), `min_cm`, `max_cm` |
| `world_objects` | `world_id`, `cx`, `cz`, `kind`, `name`\*, `x/y/z`, `yaw`, `radius`, `piece_count`, `storey_count`, `recipe` |
| `matches` | `world_id`, `key`\*, `authority`, `authority_claimed_at`, `started_at`, `last_active_at` |
| `object_damages` | `match_id`, `world_object_id`\*, `destroyed` (bitset), `partial`, `collapsed_from`, `destroyed_count` |

\* part of a unique index.

Indexes, and why each earns its place:

- `worlds.slug` unique — the only lookup, and the actual invariant.
- `terrain_tiles (world_id, tx, tz)` unique — both access patterns are point lookups on
  this composite, and its leftmost prefix covers `where(world_id:)`. Unique because a
  duplicate tile is a seeding bug that would silently double terrain.
- `world_objects (world_id, cx, cz)` — the chunk controller runs this up to 64 times per
  page load. Without it, 64 scans.
- `world_objects (world_id, name)` unique — makes the seeder idempotent by upsert, and
  makes "the building called X" findable from a test.
- `matches.key` unique; `matches.last_active_at` for the reaper.
- `object_damages (match_id, world_object_id)` unique — serves resync on the leftmost
  prefix and the flush upsert as a point lookup. Unique is what makes the upsert real.

Deliberately **no** index on `kind` (three values, no selectivity) and **no** R\*Tree.
The chunk grid *is* the spatial index and it is exact for every access pattern we have;
an rtree would need a trigger and become a second source of truth.

**Straddling objects: anchor-owns.** An object belongs to the chunk containing its anchor
and carries a bounding `radius`. Validate `radius < chunk_size` so a 3×3 ring always
contains anything that could intrude. Duplicating a row into every overlapped chunk would
split its damage state across rows, which is simply wrong.

### 3. Terrain

A heightfield, not a mesh. 500m tiles at `height_step` 5 → 101×101 samples.

**Encoding: int16 centimetres relative to a per-tile `base_cm` (int32), little-endian,
rows north→south, columns west→east** — mijnstreek's row order, so an importer is a
memcpy after the subtraction. int16-cm gives ±327m of relief *within one 500m tile* at
1cm resolution; no terrain on earth does that, and `base_cm` keeps absolute elevation out
of the range forever. Float32 would double the size for precision 500× finer than the
sample spacing can express. `min_cm`/`max_cm` are denormalised so culling and LOD never
decode the blob.

**The triangulation trap.** `PlaneGeometry` emits `(a,b,d),(b,c,d)` — a split along the
*anti*-diagonal (`three.js:13888`). Parry's heightfield uses its own fixed diagonal in its
own row/column convention, and `rotateX(-π/2)` reverses row order on top of that. They
will not agree, and the disagreement is silent: the car rests above, or sinks into,
ground that isn't where it is drawn.

So: **never use `PlaneGeometry` for terrain.** Build the `BufferGeometry` by hand from the
same height array, with one `terrainIndexBuffer(rows, cols)` whose only job is to mirror
parry's diagonal and one `terrainVertex(i, j)` mirroring its row/column mapping. Then
prove it at runtime rather than by reading Rust: `window.__arenaTerrainProbe(x, z)`
returns `{physics, render, delta}` — a downward `castRay` against the terrain collider
versus CPU barycentric interpolation over the render mesh's own triangles. A system test
samples hundreds of points, deliberately including pairs either side of each diagonal and
points at tile seams, and asserts `|delta| < 1e-3`. It touches no pixels, so it is
deterministic under SwiftShader.

`Game::Terrain::Sampler#height_at` uses the same triangle convention, not bilinear.
mijnstreek has the scar tissue: bilinear is off by up to 80cm where terrain steps across a
cell, which is how props end up floating.

World edges are four tall invisible fixed cuboids with `WORLD_GROUPS`, plus a position
clamp in the vehicle controller as a tunnelling backstop.

### 4. Materials

`Game::Materials` is a frozen table; `Game::Material` is the value object. Every number
lives here, per CLAUDE.md's rule.

Fields: `health_per_m2`, `density`, `armour` (flat subtraction per hit — what makes
concrete need a rocket rather than more bumping), `structural_weight` (1.0 brick and
concrete, 0.35 plaster, 0.0 glass and void), `fracture` params, `multipliers` per damage
kind (`impact`, `blast`, `blade`, `bull_bar`, `slam`), `colour`, `friction`, `restitution`.

Entries: `brick`, `concrete`, `plaster`, `timber`, `glass`, `roof_tile`, `steel`, `void`.
`void` is a real entry with zero everything — a door hole is a piece index with no body
and no mesh, which keeps the index arithmetic uniform.

Cell health is `health_per_m2 × cell_area × thickness_factor`, cell mass is
`density × cell_area × thickness`. Both computed in Ruby and shipped **per surface** as a
single number, never per cell.

`DamageResolver` gains `material:` and `kind:`, with `armour` subtracted after the
multipliers. That changes the ported pair, so `damage.js` moves in the same commit. The
function stays table-driven and the table ships in the spec, so no new constant enters
JavaScript.

### 5. Buildings: recipe → surfaces → pieces

**Pieces are never rows and are never materialised on the server.**

A `world_objects.recipe` is ~300 bytes: footprint ring, `base_y`, eaves and ridge heights,
roof type, storeys, palette key, seed. `Game::Building::Generator` turns it into a
`SurfaceSet` deterministically, at request time, cached.

A **surface** is a regular grid:

| field | meaning |
|---|---|
| `kind` | `wall` \| `partition` \| `floor` \| `roof` \| `gable` |
| `storey` | 0-based; roof and gable carry `storey_count` |
| `mat` | material name into the shipped table |
| `o` | origin in building-local coords, the (col 0, row 0) corner |
| `face` | 0–3 for a footprint edge, or `up`; with the building yaw this derives the u/v basis without shipping two vectors |
| `pitch` | radians; present only when non-zero |
| `w`, `h`, `cols`, `rows` | extent and grid — cell size is `w/cols × h/rows`, so cells are exact and never drift |
| `t` | thickness |
| `off` | `piece_offset`, the building-wide index base |
| `hp`, `kg`, `str` | per-cell health, mass, structural weight — Ruby has already done the arithmetic |
| `profile` | optional `["gable", rise]` — culls *geometry* only |
| `openings` | `[[col0, row0, col1, row1, type], …]`, inclusive, cell-aligned |

**The load-bearing rule: piece index space is never culled, only geometry is.**

```
piece_index = off + row * cols + col
```

for every `row < rows` and `col < cols`, always, regardless of openings or gable
profiles. A door cell consumes an index and gets material `void`. A gable's clipped corner
cells consume indices and draw nothing. This is what lets Ruby and JavaScript agree
without either running the other's cull logic, and it costs a handful of wasted bits — six
indices in a 20-byte bitset.

The client's expansion is therefore total and trivial:

```
for each cell: material = opening covering it ? (door ? void : glass) : surface.mat
```

**Generation order is part of the contract.** Walls → partitions → floors → roof → gables,
in a fixed order, `piece_offset` assigned as it goes. Change the order and every stored
damage bitset from a previous seed refers to different pieces — which is what
`content_digest` in the chunk URL guards.

**Worked example** — 8×10m, 2 storeys at 3.0m, eaves 6.0, gabled ridge 8.5. Target cells:
wall 2.0, floor 2.5, roof 2.0. `cols = max(1, (extent / target).round)`, then the cell is
`extent / cols`, so the target is advisory and the grid always exact.

| surfaces | grid | count | pieces |
|---|---|---|---|
| front + back wall, per storey | 4 cols × 2 rows | 4 | 32 |
| left + right wall, per storey | 5 × 2 | 4 | 40 |
| storey decks | 3 × 4 | 2 | 24 |
| spine partition, per storey | 5 × 2 | 2 | 20 |
| cross partition, per storey | 4 × 2 | 2 | 16 |
| roof planes (slope 4.717m) | 5 × 2 | 2 | 20 |
| gable ends | 4 × 1, `profile: ["gable", 2.5]` | 2 | 8 |

**18 surfaces, 160 piece indices**, offsets running 0, 8, 16, 26, 36, … Bitset: 20 bytes.
At a 1.5m wall cell the same house is ~250 pieces; at 1.0m, ~430. The lever is one number
in the rules block, retunable without touching JavaScript — which is the entire reason the
piece count is not in the database.

**Cell size has architectural meaning**: a 2.0m cell means a 2.0m door. Chunky but
defensible for a cartoon game. Sub-cell openings would need polygon clipping on both
sides — mijnstreek needs 626 lines of Sutherland–Hodgman for exactly this. A cell's *mesh*
can inset a frame without touching the grid; that is the escape hatch.

### 6. Delivery

**Geometry is immutable and travels over HTTP. Damage is mutable and only ever travels
over ActionCable.** Never mix them in one response — that split is what makes geometry
infinitely cacheable and keeps socket payloads to deltas.

Stays inlined in `show.html.erb`: `version`, `vehicles`, `rules`, `input` (unchanged),
`arena` (same key — renaming churns three JS files and the system tests for nothing) now
carrying world metadata and the digest-stamped chunk URL prefix, plus two new blocks —
`materials` (the whole table, ~3KB, inline because the first chunk can land before any
other fetch resolves) and `destruction` (cell targets, collapse thresholds, batch cadence,
caps, debris tuning). ~100KB becomes ~105KB; the city is strictly additive.

Moves out:

```ruby
scope "worlds/:slug/:digest", constraints: { digest: /[0-9a-f]{12}/ } do
  get "chunks/:cx/:cz", to: "chunks#show"   # application/json
  get "tiles/:tx/:tz",  to: "tiles#show"    # application/octet-stream, raw int16
end
```

Follow mijnstreek's build-on-demand-then-`send_file` precedent, with two corrections:

1. **Digest in the path, not a version threaded to the client.** Self-invalidating and
   genuinely immutable, so `expires_in 1.year, public: true, immutable: true`. Re-seeding
   writes under a new prefix. A stale digest 404s, and a stale client should reload —
   exactly what the existing `version` digest exists to make visible.
2. **Atomic writes.** `path.write` can serve a truncated file to a concurrent reader.
   Tempfile in the same directory, then `File.rename`.

**JSON for chunks, binary only for terrain.** Binary chunks would save ~150KB on the
resident ring — over a socket already relaying 20Hz snapshots — at the cost of a
hand-written packer and unpacker that must agree on field order forever. Terrain is the
opposite: 10,201 numbers, no field names for gzip to take, and the decode is one
`Int16Array` constructor. Draw the binary boundary once, at the one place it pays.

Budget: ~90 B/surface → ~1.6KB/building raw, ~300 B gzipped. ~16 buildings per 125m chunk
→ ~26KB raw / ~5KB gzipped per chunk; ~230KB / ~45KB for the 9-chunk resident ring.
Assert a 64KB per-chunk ceiling in a test.

### 7. Rendering

**`InstancedMesh` per (chunk × material), not `BatchedMesh`.** Without `WEBGL_multi_draw`
a BatchedMesh degrades to one `drawElements` *plus a uniform upload* per instance
(`three.js:29736`) — worse than today's 390 separate meshes — and its `onBeforeRender`
walks every instance twice a frame. Whether ANGLE/SwiftShader exposes that extension in CI
is not something to bet the render architecture on. `InstancedMesh` is WebGL2 core.
BatchedMesh is reserved for debris, where geometries genuinely differ and the cap is a few
hundred.

One shared unit `BoxGeometry` covers every box piece. Non-uniform scale is already
correct: `defaultnormal_vertex` (`three.js:14032`) divides by the squared column lengths,
which is the inverse-transpose for a rotation×scale matrix with no shear — so compose
every instance matrix `T · R · S`, never `T · S · R`.

**The tinting trap.** `setColorAt` is a silent no-op unless `material.vertexColors = true`
(`USE_COLOR` comes only from that flag), but once it is true the program declares
`attribute vec3 color` and `MeshStandardMaterial` has no `defaultAttributeValues` — so an
unbound attribute renders the whole city black. **Bake a constant-1.0 `color` attribute
into the shared unit cube.** Then `instanceColor` is a pure linear-space multiplier
carrying `clamp(0.35 + 0.65 × health/max) × perPieceJitter`, and `material.color` is the
shared base, never mutated. That is what replaces `destruction.js:24-25` and what finally
lets one material serve thousands of pieces. Note the colour space: today's `setStyle()`
converts sRGB→linear, so the instance colour must carry the *ratio*, not an absolute
colour.

Slots are fixed-stride runs per (chunk, material), stride taken from the chunk manifest so
it is exact. Demotion swaps the last live run into the hole and decrements `count`, so the
shader never processes dead slots. Broken pieces stay allocated at zero scale — a
degenerate triangle rasterises nothing, and keeping the slot is what makes rollback O(1).
Uploads use `addUpdateRange` so one break uploads 64 bytes, not the whole buffer. Assign
each pool's `boundingSphere` manually from the chunk AABB, or three will walk every
instance to compute it.

Shadows are the real cost — a 2048² `PCFSoftShadowMap` over a city, on a software
rasteriser in CI. Five changes: only FINE chunks cast; tighten the ortho frustum to ±70m
to match the FINE radius (the current ±90 is a leftover from the 380m arena); `PCFShadowMap`
rather than `PCFSoft`, whose extra taps land in the *main* fragment shader over the whole
screen; `shadow.autoUpdate = false` with alternate-frame updates, since the sun is static;
and quality tiers (`high`/`medium`/`low`) with `low` — shadows off, FINE 48m — used by the
system suite.

Budget at 1000 buildings: ~110 main + ~45 shadow ≈ **155 draw calls**, against today's
~780 for 390 boxes, with ~30× the geometry.

### 8. Physics and promotion

**A piece is a fixed collider with no rigid body.** A wall panel never moves, so it has no
business being a dynamic body with a `readBack` and a lerp every frame. Consequences: the
interpolation list never grows with the city; 3,800 resident pieces cost zero per-frame
work; and **breaking is `collider.setEnabled(false)`** — O(1), allocation-free, trivially
reversible, and it sidesteps the use-after-free footgun entirely, because nothing is freed
on a break. `removeCollider` is reserved for chunk unload. The whole reconciliation design
rests on this.

**Promotion granularity is the building; the chunk is only the streaming unit.**

| tier | trigger | colliders |
|---|---|---|
| LOD | chunk resident (320m in / 420m out) | 0, merged silhouette mesh |
| SHELL | 250m in / 300m out | 2–3 coarse (footprint prism, roof) |
| FINE | 80m in / 110m out | per piece |

Measured building-AABB to player, evaluated at 10Hz with hysteresis *and* a dwell counter
— hysteresis alone still thrashes for a player oscillating at walking pace. At ~1
building/1000m², FINE is ~20 buildings ≈ 3,800 colliders; total static ~4,350, well inside
Rapier's comfortable range and with no fixed-vs-fixed pairs generated. The risk is
insertion bursts, which is what the 64-collider job slice is for.

Pieces take `LAYER.PROP`, so the bull bar and slam plate reach them with no change to
`groups.js` — its own comment already promised this.

**A third wasm rule, with the same weight as the two in CLAUDE.md:** *create and remove
colliders only at frame top, before `vehicle.update`, outside the substep loop.* One
promotion burst per rendered frame, never per substep.

Forced promotion — "a rocket fired from 100m must still punch individual panels" — is
handled **predictively**, so it never needs to run mid-step. Each frame, march every live
rocket 25m along its velocity against the spatial grid and promote what it will reach; at
120 m/s that is ~6 frames of warning. An explosion knows its final radius at spawn, so the
instant a rocket detonates, promote everything whose AABB meets the full sphere. A
last-resort mid-substep path stays, capped at one building, for a rocket spawned inside a
shell.

`engine.bodies`, `trackProps`'s `getObjectByName` join and `untrack`'s linear `findIndex`
all go. Pieces live in a structure-of-arrays `piece_store` over typed arrays. The collider
registry is a hybrid: dense typed arrays indexed by Rapier's small recycled collider
handles for the thousands of pieces, the existing rich `Map` for the ≤50 vehicles, rockets
and parts. The drain hot path becomes an integer compare before it touches a `Map` — which
matters when it sees hundreds of city contacts per step.

### 9. Destruction and debris

**A hole is the absence of cells.** Break `(row, col)` → zero-scale the instance, disable
the collider. That is the whole mechanism. What sells it is that buildings are hollow: you
see through the hole into a room and out the far side. Never optimise interiors away for
FINE buildings — that is the payoff for the hollow decision.

Two cheap touches: **rim spread** bumps the ≤4 orthogonal neighbours to 30–60% damage on
break, so holes grow organically along their edges rather than appearing as clean
rectangles; and openings arrive as `void` cells, so a blast near a window tears the wall
outward from it because the neighbours are already edge cells.

three-pinata fractures a whole watertight mesh — `impactPoint` only biases fragment
density, it does not punch holes. For a 2m panel that is exactly right, because the piece
is small and entirely destroyed.

| material | method | fragments |
|---|---|---|
| glass | `voronoi` 2.5D, `projectionNormal` = surface normal | 18–24 — prismatic shards through the thickness, not diced in Z |
| timber | `simple`, `fracturePlanes: {y: true}` | 8–12 splinters along the grain |
| brick | `voronoi` 3D, `useApproximation` | 14–20, roughly brick-sized |
| concrete | `voronoi` 3D, small `impactRadius` | 20–30, dense spall at the hit |
| roof tile | `voronoi` 2.5D | 6–10, sheared flat |
| steel | none | tint and bend; no fragments |

**Patterns bake on a unit box and instance scaled**, collapsing the library to 6 materials
× 3 aspect classes × 3 seeds = 54 patterns. Anisotropic scaling skews a fragment's
silhouette, but at debris scale, tumbling, for under two seconds, nobody sees it.

**Do not bake at boot**: 54 voronoi fractures at 10–30ms each is ~1.1s of blocked main
thread, colliding directly with the 20s `wait_for` budget and making every system test
slower and flakier. Three stages instead — ship the deterministic box split that
`destruction.js:49` already implements; then lazily bake one pattern per frame within a
2ms budget, prioritised by what the player is near, with the fallback serving until a
pattern exists; then, as the endgame, a committed `app/assets/fracture_patterns.json`
produced by a `game:bake_fractures` rake task driving the existing headless-Chrome setup.
No build step, no node_modules, and an artifact that matches this repo's vendor-the-artifact
philosophy.

**Two-tier debris**, because 160,000 pieces × 20 fragments is not a number Rapier
approaches. Tier A is physical: 120 live dynamic bodies (30 at `quality=low`) under
`DEBRIS_GROUPS`, reserved for the nearest and largest fragments. Tier B is visual: 800
fragments (200 at low) with no body at all, a ballistic integrator with a terrain-height
bounce, ~12 flops each per frame. Both render through one `BatchedMesh` per material —
the one place BatchedMesh earns its keep. Fixed-size ring buffers; spawning past the cap
retires the farthest from camera. Fragment colliders default to the fragment's oriented
AABB as a cuboid; true convex hulls are cached per (pattern, fragment) for hero pieces
only.

### 10. Server-authoritative damage

**client → server**: `damage` `{seq, hits: [[object_id, piece_index, amount, kind], …]}`
batched at `snapshot_hz`; `request_state` `{cx, cz}` alongside each chunk fetch.

**server → client**: `breaks` `{t, broken: […], collapses: […]}`; `state` `{cx, cz,
authority, objects: […]}`; `error` `{reason}`.

The existing relay is untouched; `player_id` stamping is unchanged. Partial HP is never
broadcast — cosmetic darkening is local, and the server's HP only ships in a `state`.

**The invariant that makes this safe: pieces only ever go standing → broken, and collapse
only ever goes NULL → lower. Nothing un-breaks on either side.** Therefore the client
predicts its own breaks and never reverts; the server's rule is "any client's cumulative
reported damage that would break a piece, breaks it", so a self-predicted break is always
confirmed; two clients hitting the same piece only make it break sooner; and a client
receiving a `state` claiming a piece it already broke is standing simply ignores it — one
line, and it makes a post-restart rollback invisible. Without this, driving through a wall
at 30 m/s bounces you off while a round trip completes.

A mispredicted break is the ugly case, so minimise how often it is *seen*: a `PREDICTED`
piece unconfirmed for longer than `2 × RTT + 100ms` is treated as confirmed for gameplay;
a `DENY` inside the window animates the instance back from zero scale over 200ms with the
server's health as tint, leaving already-spawned debris to live out its lifetime, which
reads as "you chipped it" rather than "it reassembled".

Live state is `Game::Damage::Registry`, a process-global map of match key → `MatchState`
under a per-match `Monitor`, flushed every ~1s and on last unsubscribe by one `upsert_all`
inside `transaction(isolation: :immediate)`. Immediate is not optional: SQLite's classic
deadlock is two deferred transactions each taking a read lock then both trying to upgrade,
and taking the write lock at BEGIN removes the upgrade. WAL is already the Rails 8 default,
so chunk builds never contend with flushes, and solid_cable writes to a separate database
so broadcasts never contend with the game database either.

**Multi-process.** `config/puma.rb` has no `workers` line, so the design is correct by
default today. Make it correct *loudly*: on first subscribe a process claims the match with
a conditional `UPDATE` on `matches.authority`; a process that loses refuses `damage` and
sends `error: "not_authoritative"`, so destruction degrades to nothing rather than
diverging silently. Every `state` and `breaks` carries the winning `authority`, and the
client logs a SEVERE console error if it ever changes — which `wait_for` already surfaces.
In a single-process deployment the claim always succeeds, which is the point: an
enforcement path that is never exercised is one that does not work.

Be honest about the limits: per-hit caps, per-batch length caps and per-player rate limits
bound the blast radius of a cheating client, but they are **not security**. The server
cannot recompute damage without simulating, which is the accepted price of clients
reporting damage. There is no ranked play.

### 11. Collapse

> **Revised during implementation, 2026-09-14.** The wall-counting clause this section
> originally specified — `walls_intact < min_standing_walls (2)` — does not do what the
> prose beside it promised. Measured on the canonical house: two of four walls gone leaves
> 0.545 of the storey's area and 2 walls intact, so it *stands*, and by the time a third
> wall goes the area clause has already condemned it. The clause never fired on its own,
> and counting walls makes a 15m wall worth the same as a 3m one. Replaced with the rule
> below, which weighs how much support was removed against how much weight is still on top.

Per storey, over that storey's own surfaces:

```
weighted_area(cells) = Σ cell_area × material.structural_weight   # glass and void are 0

capacity(s) = standing weighted_area of s's walls and partitions, over its intact total
load(s)     = standing mass of every storey above s, over its intact total

storey s fails if  capacity(s) < collapse_threshold  (0.40)
                OR load(s) / capacity(s) > safety_factor  (1.6)
```

Two clauses, and each catches what the other cannot.

The first is integrity: a storey with almost nothing left fails whatever is above it. It is
the only clause that can condemn a top storey, which carries nothing but its own roof — and
a roof left hanging over a shot-out top floor is the most visible bug this feature could
ship.

The second carries the feel. Both halves are fractions of the building's own intact state,
so the rule needs no absolute area or tonnage and reads the same on a bungalow and a tower.
It makes the rule legible from the driver's seat — *knock two walls out and it comes down* —
because removing a long wall removes a real share of what was holding two storeys up. And
it gives demolition an order: take the roof and the top floor off first and those same two
walls hold, because there is nothing left for them to carry. Both numbers are in the rules
block, retunable without touching JavaScript.

On failure: destroy every piece at `storey >= s`; set `collapsed_from` monotonically, never
raised; apply `pancake_damage_fraction` of the falling mass to storey `s-1` and re-evaluate,
recursing at most `storey_count` deep — which is what makes a top-floor failure sometimes
take the whole house and usually not.

The pancake spreads over storey `s-1`'s load-bearing cells only, since those are what the
next evaluation weighs. Note what the load clause implies for the cascade: once a storey has
come down, nothing is standing above the one below it, so its load drops to zero and only
the integrity clause can still condemn it. A cascade has to be *earned* by the pancake
actually breaking things rather than following automatically. In practice the falling mass
takes out plaster partitions and timber door panels below while the brick holds, and
finishes a storey already worn down by the fight that brought the one above down.

Evaluated **server-side only**, inside `MatchState#apply_batch`, for touched storeys only.
**Deliberately not ported to JavaScript**, unlike every other per-frame behaviour in this
codebase. Individual break prediction is safe because it is monotone and self-caused;
collapse prediction is neither, and a collapse is the one event you cannot undo — it
destroys 100+ pieces and spawns a debris field. That reasoning goes in a comment at the top
of `collapse.rb`, because the temptation to port it will recur.

On the wire it is `[object_id, from_storey]` — ~20 bytes rather than ~150 indices. The
client already holds the surfaces, so expansion is a filter.

Presentation is scripted, not simulated: hide every piece at or above the storey in one
coalesced pass, replace them with **one** ground-level rubble prism (server-authoritative
dimensions, so every client drives over the same rubble — 160 colliders become 1), burst
debris from the dominant material borrowing against the global cap, and add expanding
additive dust the way `explosions.js` already does. A predicted collapse runs presentation
but **defers the rubble prism** until the server confirms; for the ~100ms gap the storey is
simply non-solid.

## Data flow

```
seed ──> World + TerrainTile rows + WorldObject recipes

page load
  └─> Game::Spec.for(world)       version, arena meta, materials, destruction, vehicles…
        └─> streamer (browser)
              ├─> GET /worlds/:slug/:digest/tiles/:tx/:tz     int16 heights  ─> heightfield
              └─> GET /worlds/:slug/:digest/chunks/:cx/:cz    surfaces       ─> piece_store
                    └─> ArenaChannel request_state{cx,cz}     ─> damage bitsets
                          └─> apply: hide pieces, disable colliders

play
  impact / blast ─> resolveDamage(part, speed, material, kind)
        └─> piece health -= damage
              ├─> local: PREDICTED, zero-scale instance, disable collider, spawn debris
              └─> batched ─> ArenaChannel damage{seq, hits}
                    └─> MatchState#apply_batch      authoritative HP, bounds-checked
                          ├─> breaks{broken, collapses}  ─> every client
                          └─> Collapse.evaluate(touched storeys)
                                └─> destroy storey>=s, rubble prism, recurse to s-1
                    └─> flush (1s debounce) ─> object_damages upsert
```

## Edge cases

- **Player outruns the loader.** Terrain never streams late: it has its own budget, a
  2-tile lookahead and top priority, because falling through the world is the one
  unrecoverable failure. LOD is always ahead of FINE, so a skyline exists at 40 m/s. If the
  player's own chunk is not even LOD-resident, the streamer raises its budget and reorders
  strictly nearest-first — a hitch, never a freeze.
- **Boundary oscillation.** Each chunk carries an epoch; every queued job captures it and
  becomes a no-op if stale. That bounds the queue no matter how the player jitters.
- **`__arenaPlace` to the far corner.** Same hard-floor path as outrunning the loader.
- **Object straddling a chunk edge.** Anchor-owns plus `radius < chunk_size`.
- **Piece index out of range.** `world_objects.piece_count` bounds check — the column
  exists for exactly this, and without it a malformed index corrupts a neighbouring
  object's bitset.
- **Process restart mid-match.** ≤1s of damage lost; rehydrate from `object_damages` on
  first subscribe. Monotone client state makes the rollback invisible.
- **Two processes, same match.** The authority claim makes the loser refuse; the stamp
  makes it visible.
- **Stale client, old digest.** Chunks 404 and the client reloads — the `version` digest
  already exists to make staleness loud rather than mysterious.
- **Blast through cover.** Still a distance query, not a collider — unchanged from today.
- **Collapse while a piece is PREDICTED.** Collapse wins; it is terminal and monotone.
- **Building with no valid footprint** (degenerate ring from a future import). The
  generator rejects it and the seeder skips it, as mijnstreek drops parts under 0.5m².

## Testing

**Fast, no browser.** The worked example is a test: 18 surfaces, 160 pieces, the exact
`piece_offset` sequence — the regression net for "generation order is part of the
contract". `surface_for(index)` inverts `piece_index(row, col)` for every cell of a random
set of surfaces. Openings never cull index space. Heights codec round-trips, clamps, and
is little-endian. `Frame.mijnstreek` asserts origin 185000/330000, tile 500, step 10, n 51
— compatibility as a failing test, not a comment. Terrain sampling picks the *triangle*,
not the bilinear average, where a cell steps. Collapse: perforated middle survives, two
walls gone collapses, threshold exactly at the boundary, pancake cascades, pancake stops,
`collapsed_from` never raises. Bitset boundaries at bits 0, 7, 8 and the last bit of a
non-byte-aligned count. Out-of-range and over-cap hits rejected. One seeder test builds the
full 1000-building city and asserts it completes **under 5s**, so a regression fails rather
than merely feels slow.

Generators return value objects and a separate seeder persists them, so almost all of this
is DB-free — which is also why the ~1,500 lines of vehicle tuning assertions in
`world_test.rb` need nothing but `Game::World.build` → `Game::Spec.for(…)`.

**Browser**, under SwiftShader with no GPU. Every claim above is about counts and state
rather than pixels, so all of it is assertable headless. `__arenaTerrainProbe` over
hundreds of samples is the parity test for the ported sampler — the one CLAUDE.md notes is
missing for the existing pairs. `__arenaBreak` / `__arenaServerBreak` / `__arenaServerDeny`
/ `__arenaServerCollapse` make destruction and reconciliation testable without driving into
anything, removing the largest source of flakiness in the existing suite. `__arenaStreamWait()`
replaces sleeps. `__arenaDraws` from `renderer.info.render` turns "did the render plan
regress" into one assertion. Plus `__arenaWorld`, `__arenaBuildings`, `__arenaPieces`,
`__arenaColliders`, `__arenaDebris`, `__arenaGl`, `__arenaQuality`.

The suite runs at `?quality=low&fracture=off` and pins `?world=` explicitly from the moment
that parameter exists, so flipping the default is one line rather than a test rewrite.

## Migration notes

- **`Game::World` → `Game::Spec`.** Inside `module Game` a bare `World` resolves to
  `Game::World`; a `::World` Active Record model alongside it is a bug with a long fuse.
  Three files touch it.
- **`Game::Arena` is deleted**, after a characterisation test proves
  `Generators::ProvingGround.build.to_spec == Arena.build.to_spec` byte for byte. The test
  is temporary and goes with the class. `Game::Track` is reused verbatim — the spline is
  tuning, so the generator runs it and the *output* becomes rows.
- **`StaticBody` and `DestructibleProp` survive unchanged.** A crate is one dynamic body
  that tumbles; a wall panel is one fixed collider in a grid. Those are different things,
  so `world_objects.kind` is `building` | `static` | `prop` and the client keeps a small
  furniture path beside the city path. `arena_view.js` is absorbed into the chunk so
  furniture streams too.
- **`damage_resolver.rb` → `damage/resolver.rb`**, material-aware. `damage.js` moves in the
  same commit, per the paired-port rule.
- `world_test.rb:9`'s key list gains `materials` and `destruction` — the single most
  visible line of the feature. Its arena assertions move to
  `generators/proving_ground_test.rb`.
- The proving ground must keep the coordinates the system tests aim at: `aim_at_crates` is
  `(0, 2.0, −32)` in `hit_feedback_test.rb:94` and `(−66, 1.2, −36)` in
  `abilities_test.rb:279`; `aim_at_pillar` is `(−40, 1.2, −17)`. `driving_test.rb` places at
  the origin and calls it "flat infield", so the proving ground must guarantee zero terrain
  height there — worth an explicit assertion.
- **CLAUDE.md** needs four edits, three of which correct statements this work invalidates:
  the Active Record / PORO split; the four new ported pairs plus the note that
  `Damage::Collapse` is deliberately *not* ported; the one-authoritative-process constraint;
  and the geometry-over-HTTP / damage-over-socket split with digest-in-path invalidation.
  Plus the workspace conventions — the 31xx port band, `.dev-port`, and the machine-wide
  system-test lock that lets several worktrees share one machine.

## Out of scope

- **3DBAG and AHN import.** The schema is built for it and the frame makes it a subtraction,
  but the rake task is later work.
- **Remote-vehicle wiring.** `net/{connection,snapshot,remote_vehicle}.js` remain unimported.
- **Sub-cell openings**, per §5.
- **Full structural support graphs.** Per-storey pancake is a deliberate trade of fidelity
  for authority: it is O(storeys) rather than O(pieces), and one integer on the wire.
- **Blast occlusion by cover.** Unchanged from today.
- **A Web Worker for streaming.** A module worker would need to re-resolve bare `"three"`
  through a digested Propshaft URL and parse 1.3MB per worker. Budgeted main-thread slices
  get the same smoothness without that trap.
