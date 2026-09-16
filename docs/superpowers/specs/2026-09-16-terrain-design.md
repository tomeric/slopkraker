# Terrain: the ground gets elevation

Date: 2026-09-16
Status: designed. Builds the client half of §3 of `2026-09-13-persistent-world-design.md`,
whose Ruby half — `Game::Terrain::{Frame, Tile, HeightsCodec, Sampler}`, the
`terrain_tiles` table and `World#frame` — has been built, tested and wired to nothing
since. This document does not redesign §3; it says how the code that exists is put to
work, decides the two things §3 left open, and records what the running Rapier build
actually does where §3 could only warn.

## Why now

Terrain is the last item in the original brief with nothing to show. It was parked behind
destruction deliberately, and destruction is done: collapse, falling slabs, rubble and
remnants have all landed. Flat ground cannot import a real city, and importing one from
3DBAG and AHN is the point of the whole persistent-world design. `Frame.mijnstreek` is
already written so that compatibility with the sibling map app is a failing test rather
than a comment. What is missing is the ground itself.

## The hazard, settled by measurement

§3 warned that `PlaneGeometry` splits its cells along the anti-diagonal while parry's
heightfield uses "its own fixed diagonal in its own row/column convention", that
`rotateX(-π/2)` reverses row order on top of that, and that the disagreement is silent.
The warning was correct in every particular except one: it did not know which way parry
splits. Rather than read Rust, a Node script drove the vendored `rapier3d-compat` build
(`@0.20.0`) directly — a 4×4 heightfield, one sample raised at a time, a downward
`castRay` at both half-centroids of every cell — and the answers are:

- **`ColliderDesc.heightfield(nrows, ncols, heights, scale, flags)` takes CELL counts**,
  not sample counts: `heights.length` must be `(nrows + 1) * (ncols + 1)`.
- **The heights matrix is column-major.** Sample `(i, j)` lives at `heights[i + j * (nrows + 1)]`.
  Row `i` runs along the collider's local **z**, column `j` along local **x**, the field
  spans `[-scale/2, +scale/2]` on each, and `y = heights * scale.y`.
- **Every cell is split on the anti-diagonal**: the shared edge runs from the cell's
  south-west corner to its north-east one, so a point is in the first triangle when
  `fu + fv <= 1`. No zigzag, no checkerboard. **This is exactly `Tile.interpolate`'s
  convention**, so the Ruby side needs no flip and the JS port is a straight transcription.
- `RAPIER.HeightFieldFlags.FIX_INTERNAL_EDGES` exists and is set; it stops a body
  catching on the internal edges between triangles and does not change the triangulation.
- **A vertical ray exactly on a grid line can miss** (found by the survey, not the spike).
  On `hills`, a ray straight down on 28 of the 79 row lines, or 28 of the 79 column
  lines, gets no hit from Rapier anywhere along that line, while a centimetre off it
  hits, and the drawn triangles and the sampler agree with each other there. That is
  float32 rounding of the cell index in parry's vertical-ray special case, which tests
  one cell's two triangles and never falls back to the neighbour: a raycast quirk over a
  measure-zero set, not a disagreement about height. The survey keeps its seam probes a
  quarter metre off the perpendicular grid lines and says so. A moving car's wheel rays
  are cast along the chassis's own down, so they are exactly vertical only on level
  ground, and exactly on a grid line only by float coincidence.

Our blob is rows north→south (row `i` runs with z), columns west→east (column `j` runs
with x), row-major. So the physics array is the blob **transposed** into column-major,
and a mesh vertex `(i, j)` sits at `(origin_x + j·step, h[i·n + j], origin_z + i·step)`.
Two functions carry that and nothing else:

- `terrainIndexBuffer(n)` — for every cell `(i, j)` the two triangles
  `(v(i,j), v(i+1,j), v(i,j+1))` and `(v(i+1,j), v(i+1,j+1), v(i,j+1))`, which is the
  anti-diagonal split wound counter-clockwise seen from above.
- `terrainVertex(i, j)` — the row/column-to-world mapping above.

`PlaneGeometry` and `rotateX` appear nowhere.

**The measurement is not the proof.** A Node spike against one build proves what that
build does today. The proof is `window.__arenaTerrainProbe(x, z)`, which returns
`{ physics, render, sampled, other, delta }`:

- `physics` — a downward `castRay` against colliders whose registry kind is `terrain`.
- `render` — barycentric interpolation over **the render mesh's own triangles**: find the
  tile and cell, read that cell's six indices from the geometry's index buffer, pick the
  triangle containing `(x, z)`, interpolate `y` from the position attribute. This path
  reads the buffers three.js draws from, not the formula that built them.
- `sampled` — the client sampler, `Terrain#heightAt`, the port of `Tile.interpolate`.
- `other` — what the **opposite** diagonal would have said. This is how the test proves
  it has teeth: a survey in which `other` never differed from `render` would pass whatever
  Rapier did.
- `delta = physics - render`.

`terrain_test.rb` runs a survey in the page — both half-centroids of every cell of every
tile, points every half metre along both tile seams, and a deterministic scatter — and
asserts `max |delta| < 1e-3` and `max |other - render| > 0.02`. It touches no pixels, so
it is deterministic under SwiftShader.

## Decision 1: tiles travel over HTTP, per §6, from the first tile

The alternative was inlining one tile as base64 in the spec. It is the cheaper first step
and it is a dead end: an imported town is a dozen or more tiles of 5–20 KB, which as
base64 in the page is a quarter to half a megabyte on every load, so it would be replaced
by the endpoint the moment the importer exists. The brief asks that nothing here force a
rewrite. §6 is followed:

```ruby
scope "worlds/:slug/:digest", constraints: { digest: /[0-9a-f]{12}/ } do
  get "tiles/:tx/:tz", to: "terrain_tiles#show", as: :world_tile,
      constraints: { tx: /-?\d+/, tz: /-?\d+/ }
end
```

`TerrainTilesController#show` finds the world by slug and the tile by `(tx, tz)`, 404s
when either is missing **or when the digest does not match**, sets
`expires_in 1.year, public: true, immutable: true`, and `send_data`s the blob as
`application/octet-stream`. Three deliberate departures from §6's text, each with a reason:

- **The digest is the TILE's, not the world's.** `Digest::SHA256.hexdigest(heights)[0, 12]`.
  `worlds.content_digest` is a hand-written string on every fixture (`flatworld001`),
  nobody updates it, and a browser that has cached a tile as immutable for a year would
  keep serving old ground through every change to the height function during
  development. A per-tile digest is exactly as immutable as the bytes: the URL changes if
  and only if the tile does. The route shape is unchanged, the segment is opaque to the
  client, and a future `chunks/:cx/:cz` under the same scope is free to use the world's
  digest — the client never composes a URL, it is handed one per tile.
- **No file cache, so no tempfile-and-rename.** §6's atomic-write advice is for
  build-on-demand-then-`send_file`. A tile is a seeded row; `send_data` from the column is
  one query and there is nothing to build. Chunks, generated from many rows, may earn a
  file cache later; a tile does not.
- **The client never composes a URL.** Each manifest entry carries its `url`, built by
  `TerrainTile#manifest_entry` through `Rails.application.routes.url_helpers`. The Active
  Record model is the boundary to Rails; the PORO manifest under `Game::Terrain` sees
  only strings.

The spec gains `arena.terrain`, `null` for a world without tiles:

```json
{ "srid": null, "origin": [0, 0, 0], "tile_size": 200, "height_step": 5, "height_n": 41,
  "chunk_size": 100,
  "tiles": [ { "tx": -1, "tz": -1, "base_cm": 37, "min_cm": -695, "max_cm": 770,
               "url": "/worlds/hills/3f2a9c1b7d0e/tiles/-1/-1" }, … ] }
```

The first six keys are `Frame#to_spec`, unchanged and finally used. `min_cm`/`max_cm`
are what §3 denormalised them for: the client sizes the bounds walls and the probe ray
from them without decoding a blob. Because the URLs carry digests, `version` changes when
any tile does, which is what the version exists for.

Boot becomes `Promise.all([ loadRapier(), loadTerrain(spec.arena.terrain) ])`. A tile
that fails to load throws with its coordinates and status, so the page shows
`Failed to start: terrain tile (-1, 0) returned 404` rather than a car falling through
where the ground should have been. `loadTerrain(null)` resolves to `null` and every
flat world boots exactly as before.

## Decision 2: a fixture generates its blob from a named function

`worlds.yml` says *"nothing binary has to go in a fixture"* because no world carried
tiles. The `hills` world does, and checking in bytes would mean a blob nobody can read
or regenerate. Instead:

- `Game::Terrain::Hills.height_at(x, z)` is a plain deterministic function of game
  metres — three cosine terms, chosen so the origin is a **level hilltop** (every term is
  a cosine, so every gradient is zero there), the relief is about **±7.7 m**, and the
  smallest term has a 13 m × 17 m wavelength, which twists each 5 m cell by up to **12 cm**
  so the two diagonals disagree by up to 6 cm at cell centres. That twist is what gives
  the probe survey something to catch.
- `Game::Terrain::TileBuilder.encode(frame:, tx:, tz:) { |x, z| … }` walks one tile's
  samples rows north→south, columns west→east, and returns `base_cm`, `min_cm`, `max_cm`
  and the packed blob through `HeightsCodec`. It is the same thing the importer will
  call with a block that reads AHN instead of a formula.
- `test/fixtures/terrain_tiles.yml` calls both in ERB and writes the blob with YAML's
  `!!binary` tag, which Psych decodes to a binary string before Active Record sees it
  (verified against this Rails). Tests load the fixture; `db/seeds.rb` loads the same
  fixture into development; the browser fetches the row's bytes over the endpoint. One
  definition, three consumers, no way for them to disagree — which is the entire reason
  worlds live in fixtures.

The function is Ruby and only Ruby. The client never evaluates it: it receives bytes.
That is what makes `Sampler` against `Terrain#heightAt` a genuine parity test rather than
two implementations of the same formula.

## The `hills` world

| | |
|---|---|
| bounds | `[-200, -200, 200, 200]`, like the others |
| tile_size / height_step / chunk_size | **200 / 5 / 100** |
| tiles | four, `(tx, tz) ∈ {-1, 0}²`, 41 × 41 samples, 3 362 bytes each |
| spawn | `[0, 9.7, 0]`, yaw 0 — on the hilltop, facing the slope down to +z |
| objects | one three-storey gabled house, the `targets` recipe with its own seed |

Two hundred rather than the default five hundred, because four 200 m tiles cover the
400 m world exactly and put **both seams through the middle**, where the tests drive.
Four 500 m tiles would cover a square kilometre for a 400 m world and put the seams
under the spawn too, at fifteen times the geometry. Nothing on the client knows the tile
size except by reading the spec, so a 500 / 10 import world costs no code. `chunk_size`
is 100 because 125 does not divide 200 and `World` validates that it must; chunks are
still unused.

**The house stands on a slope, on purpose.** Its `y` is the mean of the terrain under
its four footprint corners — a seeder concern, exactly as the brief says, and not a
recipe field — so it is buried a few tens of centimetres uphill and clear by the same
downhill. The site is chosen so that the terrain under the house and its 3 m rubble skirt
spans well over half a metre. That spread is what lets a test tell "heaps placed on the
terrain" from "heaps placed on the building's base height", which on a level site are
the same number.

`piece_count` is measured and written down as every other building's is, and
`world_summary_test` already checks every building.

`flat`, `targets` and `street` are untouched. Their timing assertions are calibrated on
flat ground, and the narrow-world fixtures exist because the old arena measured braking
on a cambered corner.

## Client architecture

Everything terrain-shaped lives in `app/javascript/game/world/terrain.js`; physics and
rendering each get a small builder beside the code that builds the rest of the world.

- `loadTerrain(manifest)` fetches every tile, decodes `Int16Array → Float32Array` metres
  (`(cm + base_cm) / 100`) and returns a `Terrain`. One `Float32Array` per tile serves
  the collider, the mesh and the sampler, so the three agree on every sample to the bit.
- `Terrain#heightAt(x, z)` is the port of `Sampler#height_at` → `Tile#height_at` →
  `Tile.interpolate`: `floor` to a tile, `floor` to a cell, clamp to `n - 2`, then the
  triangle. **Never bilinear** — the sibling map app measured bilinear 80 cm off where
  terrain steps across a cell, which is how props float. Outside every tile it returns
  the sampler's fallback, `0`, as Ruby does.
- `createTerrainColliders(RAPIER, world, terrain, rules, colliderIndex)` — one
  heightfield per tile on `WORLD_GROUPS`, translated to the tile's centre, scale
  `(tile_size, 1, tile_size)`, friction and restitution from `rules.terrain`, contact
  force events with the same threshold as every other static, registered as
  `{ kind: "terrain" }`. Wheel rays use `WHEEL_RAY_GROUPS = groups(ALL, ALL & ~RUBBLE)`,
  whose filter includes `WORLD`, so they find the heightfield with no change; the
  driving test proves it rather than assuming it.
- `render/terrain_view.js` — one `BufferGeometry` per tile from `terrainVertex` and
  `terrainIndexBuffer`, `receiveShadow`, no `castShadow`. Vertex **normals come from the
  sampler**, by central differences through `heightAt` at `±step`, which crosses tile
  seams and so leaves no shading seam where two tiles' own triangles would each have
  computed a different edge normal. Vertex **colours** blend `rules.terrain.colours.low`
  to `high` by height and toward `steep` by slope, with `material.vertexColors = true`
  and the attribute always bound — the tinting trap in §7 is about an *unbound* colour
  attribute, and this one is written for every vertex.
- `createWorldBounds(RAPIER, world, bounds, floor)` gains `floor`: the walls now reach
  from `floor - 10` to the same 60 m top. Without it a valley seven metres below zero is
  seven metres of open air under a wall whose bottom is at zero. `floor` is
  `min(min_cm) / 100` over the tiles, or `0` without terrain, so every flat world's walls
  are as they were. The vehicle-controller position clamp the brief mentions does not
  exist today and is not added here.

### What else moves once the ground is not flat

Each of these takes a `ground(x, z)` function — `terrain.heightAt` when there is terrain,
otherwise a fallback that reproduces today's behaviour exactly, so the three flat worlds
are bit-identical:

- **Rubble.** `heapFrame` takes `ground` as its last parameter and uses it for
  `out.ground` at the heap's jittered `(x, z)`; without it the existing
  `POSITION.y - |t| / 2` stands. Nothing else in `rubble.js` changes: the grid, the
  order, the seed, the chunks are all geometry over that one number. Per the comments
  there, nothing lifts or flattens a heap along the surface's axes.
- **Debris and remnants** already say *"the ground is flat at y = 0 for every world so
  far; when terrain arrives this samples the heightfield instead."* They now do: a
  shard's rest height is `ground(x, z)` plus its own thickness, re-evaluated as it
  moves, and a remnant's the same.
- **Chase camera.** On a downhill slope the camera behind the car goes under the mesh and
  looks up through a single-sided world. `ChaseCamera#update` clamps its smoothed
  position to `ground(x, z) + camera.ground_clearance`, a new tuning number in both
  vehicles' camera blocks. Not in the brief's list, but the hills world is unplayable
  without it and it is one line against a number in Ruby.
- **Spawns** keep their explicit `y`; the hills fixture computes it from the function.
  `respawn` and `placeAt` are unchanged, and `respawn_height` stays unused as it is today.

### Nothing crosses the wire

A heightfield is fixed geometry. The server never samples terrain during play, `damage`
and `breaks` are unchanged, and `Game::Terrain::Sampler` is used server-side only by
tests and, later, by the seeder. `Game::Building::Recipe`, the generator and the
piece-index arithmetic are not touched.

## The parity test, which terrain makes load-bearing

Three JS files refer to a "parity system test" that does not exist. Terrain adds a
fourth ported pair — `Sampler`/`Tile.interpolate` against `Terrain#heightAt` — and a
divergence there floats props silently, so `test/system/parity_test.rb` is written for
all of them. `game/parity.js` installs `window.__arenaParity` at boot with one entry per
pair, each taking its inputs from the page so a test can hand both sides the same cases
in one round trip:

| Ruby | JavaScript | Cases |
|---|---|---|
| `Game::TurboBar` | `turbo_bar.js` | a script of draws and updates against the truck's `turbo_bar` spec; level after every step |
| `Game::DamageResolver` + `Part#armed?` | `damage.js` | every part of both vehicles × every material × every kind, with states that arm and disarm the bull bar and the slam plate |
| `Game::Explosion#radius_at/force_at` | `explosionRadius/Force` | the already-exposed hooks, over a sweep of times and distances |
| `Game::Building::Surface` | `surface.js` | every cell of the hills house: `(piece_index, material)` |
| `Game::Terrain::Sampler` | `Terrain#heightAt` | four hundred points over the hills world, seams and cell centres included |

Tolerances: `1e-9` for the pure arithmetic pairs, `1e-4` for terrain, because the client
holds samples as `float32`. The test boots `hills` once — it is the only world with
terrain and it has a house.

## Testing

**Ruby, no browser.** `TileBuilder` produces `n²` samples with a centred base and
round-trips; two neighbouring tiles agree along their shared edge to the centimetre.
`Hills` is level at the origin, within ±20 m, and identical on every call. `World#terrain`
is `nil` for a tileless world and a manifest with one `url` per tile otherwise;
`World#sampler` samples the fixture. `Spec` ships `arena.terrain` as `null` for `flat`
and with four tiles for `hills`, and `rules.terrain` and `camera.ground_clearance` exist.
`TerrainTilesController` returns the row's bytes, `application/octet-stream`, a
`Cache-Control` carrying `immutable`, and 404 for a wrong digest, an unknown tile or an
unknown world. `world_summary_test` covers the new house's `piece_count` as it does every
other.

**Browser.** `terrain_test.rb`: the probe survey; the car spawns on the hilltop, drives
down it for 2.5 s and ends grounded with `y - heightAt(x, z)` within the suspension's
range; the house, wrecked through `__arenaDamagePiece`, leaves every standing heap with
`__arenaHeapGround(piece, id) == heightAt(x, z)` to `1e-3`, and those grounds span more
than 0.3 m. `parity_test.rb` as above. Both name their own `match`. `boot_test`'s spec
shape check gains the `terrain` key.

## Hooks added

| Hook | Purpose |
|---|---|
| `__arenaTerrainProbe(x, z)` | `{ physics, render, sampled, other, delta }`, or `null` off the terrain |
| `__arenaTerrainHeight(x, z)` | `Terrain#heightAt`, for the parity test and for tests that need the ground under a point |
| `__arenaHeapGround(piece, id)` | the ground a heap was placed on, so "heaps sit on the terrain" is one read per heap |
| `__arenaParity` | the five parity entries above |

## Out of scope

- The AHN / 3DBAG importer and any rake task. `TileBuilder.encode` with a block is its
  entry point.
- Chunk streaming, `chunks/:cx/:cz`, `Game::Chunks::Grid`. Still cold.
- Terrain LOD, textures, or more than one material. Vertex colours by height and slope
  are what the driver needs to read the relief.
- Terrain deformation. A heightfield is fixed geometry and the server never samples it.
- A vehicle position clamp at the bounds. It does not exist today and this does not add it.
