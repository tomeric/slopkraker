# Geleen: two islands from 3DBAG and AHN

Date: 2026-09-18
Status: designed. Follows the spike in `docs/superpowers/spikes/2026-09-18-dassenkuillaan/report.md`,
whose findings this document turns into decisions. Appearance — surface detail, palettes,
garages and gardens — is the next design, not this one.

## Why

The four worlds are hand-made. The persistent-world design (§1, §5) was written so that
real 3DBAG buildings on real AHN ground would be "a subtraction and nothing else", and the
spike proved the last missing piece: a terrace row of attached houses generates as one
building with one roof, party walls once, and gables only at the ends, from nothing but the
3DBAG parts and their LoD2.2 roof faces. It also found what the hand-made worlds could not:
the collapse rule condemns a whole building, and a whole terrace or a whole church is the
wrong unit for that. And it found that the server drops damage silently past 512 hits.

This design builds a fifth world, `geleen`: the estate around Dassenkuillaan and the
Sint-Marcellinus church a kilometre to the south-east, each with its surroundings, on real
terrain, joined by the real road network with nothing else in between. Two islands rather
than the corridor, because the corridor is 490 `Pand` and the whole circle 8,500, and
that is the streaming job.

## Decisions

### 1. The world

| | |
|---|---|
| slug / name | `geleen` / Geleen |
| frame | `Frame.mijnstreek`: SRID 28992, origin (185000, 330000), 500 m tiles, 10 m step, 125 m chunks |
| `origin_z` | **60.0 m NAP.** Estate ground is 63.8–65.8 m, the church's 54.1–56.9 m; game y runs about +4..+6 at the estate and −6..−3 at the church. A round number rather than a mean; `HeightsCodec` centres every tile on its own base anyway |
| islands | estate: 50 m around RD (186330, 332234) → 54 `Pand`; church: 60 m around the centroid of `NL.IMBAG.Pand.1883100000047987`, RD (187006, 331447) → 34 `Pand` |
| bounds | `[1150, -2350, 2100, -1350]` in game metres, 950 × 1000 m |
| terrain | nine tiles, `tx 2..4`, `tz -5..-3`, from AHN |
| roads | every OSM road of kind residential, living_street, tertiary, secondary, service or cycleway inside the bounds, as drawn ribbons (§6) |
| spawns | `[0]` on Muldershof at the estate centre facing south-east; `[1]` on Leursstraat beside the church. `?spawn=1` picks the second (§7) |
| gravity, materials, rules | as every other world |

Budget, from the spike's measurements: ~90 `Pand`, ~30 k pieces, ~600 KB of spec before
rounding (§5) and ~450 KB after, ~60 k instances, and draw calls that track materials, not
buildings. This is the largest world by a factor of three and it stays inline. Nothing here
grows past it without streaming.

The church island's radius is an importer parameter. Sixty metres brings its 34 `Pand`
(10 sheds, 9 houses, 15 larger buildings); eighty would bring 70. Sixty is the budget's
choice, not a geometric one.

### 2. The `row` recipe and its generator

A second recipe kind beside `building`, dispatched on `recipe["kind"]` by
`Game::Building::Generator`. The existing `building` path is untouched and the four worlds
generate byte-for-byte what they generate today (their `piece_count`s are asserted by
`world_summary_test`).

```json
{ "kind": "row", "category": "house", "pands": ["050227", "050228"],
  "yaw": -2.334, "cell": 1.0, "seed": 227,
  "band": [0.0, 8.95], "storeys": 2, "storey_height": 2.865, "eaves": 5.73, "ridge": 9.03, "roof": "gable",
  "dwellings": [ { "x0": 3.0, "x1": 8.8 }, { "x0": 8.8, "x1": 14.7 } ],
  "boxes": [ { "ring": [[0.0, 4.8], [3.2, 4.8], [3.2, 11.2], [0.0, 11.2]], "eaves": 2.78, "ridge": 2.78,
               "storeys": 1, "roof": "flat", "door": false, "solid": false, "bay": 0 } ],
  "footprint": [[0.0, 0.0], [17.5, 0.0], [17.5, 11.6], [0.0, 11.6]] }
```

Everything is in the **row frame**: local x along the row, local z across it, the street at
z = 0, every coordinate positive, and `yaw` turning local into world about the object's
`(x, z)`. The generator builds every surface in that frame with the existing `Walls`,
`Openings`, `Interior`, `Roof` and `Rubble` modules and then rotates each surface's
`origin`, `u` and `v` by `yaw` (`Surface#rotated`) before offsets are assigned. Nothing
downstream knows: the client already reads `o`, `u`, `v`, `n` per surface, `heapFrame`
works in world terms, and `chunking.js` works in cell indices. The spike rendered the
estate 46° off the grid this way with no client change.

**The order is the contract**, pinned by a worked example in `row_test.rb` with a real
pair from the data (offsets, kinds, bays, `piece_count`):

1. per dwelling in x order: front wall per storey, then back wall per storey
2. the row's two end walls, per storey
3. party walls between neighbours, per storey — brick, no openings, `shared`
4. per dwelling: decks then partition (`Interior.build` on the dwelling's rectangle)
5. per dwelling: its section of the roof — two planes cut at the party lines, and a gable
   end on the first and last dwelling; or one flat deck per dwelling
6. boxes in recipe order: the kept walls per storey, a deck per storey, then the roof
7. rubble, last, over `footprint`

Cutting the roof planes at the party lines is what lets a dwelling fall on its own (§3);
the ridge stays continuous because adjacent sections lie in the same plane. The overhang
is only on the row's ends.

**Boxes** are the one-storey and multi-storey rectangles-or-rings attached to or standing
beside the dwellings: annexes, sheds, garages, and every part of a church. A box's walls
follow its ring, and an edge is dropped when both ends lie on or inside the row's
rectangle, or inside an earlier larger box, or when it coincides with a wall already kept
— so nothing is generated twice where two things meet. Its decks and flat roof are grids
over the ring's box, void where a cell centre falls outside the ring or inside the row or
a bigger box. Roof kinds: `flat`, `gable` (over the ring's box, `Roof.gable`), and
**`pyramid`** — four triangular planes from the eaves to one apex, each a rectangle clipped
with void exactly as a gable end is. `solid` gives no openings (sheds); `door` puts the
front door on edge 0.

A recipe with no dwellings is legal: sheds and churches are rows of zero dwellings and N
boxes, and the same generator handles them.

**Openings** are the existing `Openings` with one change: a box with fewer than three
columns on its door face gets no door, because a door three cells wide on a two-cell face
is the whole face under a steel lintel. Per-category openings density and garage doors
are the appearance design's.

**Cell size** is per recipe, and the importer picks it by category: 1.0 m for houses,
sheds and their boxes, 2.0 m for churches and halls (a church at 1.0 m costs one and a half
streets). The gable-end and pyramid clipping already work at any cell size.

### 3. Bays: collapse per dwelling, per part

Measured on the spike: gutting one dwelling of a row of four to its party walls leaves 69%
of the row's ground-floor support and the row stands; a semi-detached pair cannot be
brought down by going through both houses; taking the whole ground storey out of the
Sint-Marcellinus nave leaves 65% because the tower and chapels share "storey 0". Collapse
evaluated over a whole row or a whole church is the wrong unit.

A **bay** is the part of a building that stands or falls together: one dwelling, one box.
Every surface carries `bay` (an integer, default 0), and a party wall carries
`between: [i, i+1]` instead — it is **shared**: it supports both bays and is felled by
neither. The rubble surface carries `bays`, one bay index per cell, assigned in Ruby by the
generator (a heap belongs to the dwelling whose x-interval its centre falls in, or to the
nearest box) and shipped like `blocks`, so both sides read one array and nothing is
recomputed in two languages.

The row generator assigns: dwelling i's fronts, backs, decks, partition, roof section and
gable → bay i; the end walls → bay 0 and bay n−1; party walls → `between`; a box → the
`bay` written on it in the recipe. The importer chooses that: the dwelling the box
overlaps most along the row, or, when there are no dwellings, the box's own index — so
every part of a church is a bay of its own. The generator never guesses a bay; a box
without one fails validation. The `building` recipe puts everything in bay 0 and has no
shared surfaces, which is exactly today's behaviour.

`Game::Damage::Collapse.evaluate` runs the existing rule once per bay over that bay's
surfaces plus its shared walls:

- support (`structural_area`) counts the bay's own load-bearing surfaces in full and each
  shared wall at **half** — a party wall is half yours. Counted in full, a mid-terrace
  dwelling keeps 70% of its support with its front and back gone and never falls; at half,
  front and back gone leaves 56% and it comes down, an end dwelling needs its partition to
  go as well, and a party wall taken out condemns both neighbours. Those are the answers a
  player expects.
- load (`mass_above`) and `fell_from` cover the bay's own surfaces only. A collapsing bay
  never fells a shared wall, so its neighbour's support is unchanged and a row does not
  domino. The party walls stand as freestanding walls with the neighbour attached, which
  is what a terrace does.
- `collapsed` is a map `{ bay => from_storey }`, monotone per bay, replacing the single
  `collapsed_from`. Pancaking stays within the bay.

Wire and rows change with it:

| | before | after |
|---|---|---|
| `breaks.collapses` | `[object_id, from_storey]` | `[object_id, from_storey, bay]` |
| `state.objects[].collapsed_from` | integer or null | `collapsed: { "0": 1 }`, a map bay → storey |
| `object_damages.collapsed_from` | integer | `collapsed` JSON map, migrated from the integer as `{ "0": n }`, the old column dropped |
| `Rubble.revealed_count` / `pile_indices` | per building | per bay: the heaps whose `bays[cell]` is the bay, outward from the middle of that bay's heaps |
| client `Building#collapse(from)` | fells `storey >= from` | `collapse(bay, from)` fells `bay == bay && storey >= from`; never a shared surface |
| client rubble reveal | one pending count | per bay: expected slabs and pending heaps counted per bay, so a second dwelling falling does not reveal the first one's wreckage early |

Hooks: `__arenaCollapses` counts bay collapses; `__arenaBuildingStanding` is unchanged (a
row's count moves when any bay does); `__arenaBays(id)` returns `{ bay => collapsed_from }`.

### 4. Damage batches are never silently truncated

`MatchState.apply_batch` keeps the first `MAX_HITS_PER_BATCH` (512) hits and drops the
rest without a word. Measured: knocking out a church's ground storey in one frame reached
the server as exactly 512 broken pieces, under the threshold, while the client showed every
wall gone. The cap stays — it bounds what one bad client can do — but:

- the client splits a batch into messages of at most `rules.damage.max_hits_per_batch`
  hits, the number shipped from `MAX_HITS_PER_BATCH` so the two cannot disagree;
- the server, given more than the cap in one message, applies the first cap's worth as
  now **and** replies `error: "batch_truncated"` to the sender, so it is never silent.

A system test breaks more than 512 pieces of one building in one frame through
`__arenaDamagePiece` and asserts the server's broken count equals the client's.

### 5. Spec bytes: geometry is rounded, health is computed once

Measured: a surface costs ~516 bytes, of which a fifth is sixteen-digit floats in rotated
`o`/`u`/`v`/`n`. `Surface#to_spec` rounds vectors to 5 decimals and `w`, `h`, `t` to 3.
That is geometry only; no health or mass is derived from it on the client.

Health and mass ARE derived on both sides — `hp`/`kg` in the spec for the client, and
`Material#health_for` in `ObjectState#remaining` for the server — so they must be the
same number to the last digit or a client breaks a piece the server still holds standing.
Rounding happens inside `Material#health_for` and `#mass_for` (3 decimals), which both
paths call, and `surface_test` asserts the spec's `hp` equals `health_for` exactly; the
client never computes health, so there is no JS side to hold to parity. Rounding the spec
alone would have introduced exactly the silent desync this codebase exists to prevent.

Hoisting the per-material tables out of each surface is a further 16% and is left for
when the byte budget needs it.

### 6. Roads are drawn, not simulated

The two islands' bounds hold 1,083 segments of drivable road (24 km) and 286 of cycleway.
`street` makes its one road a static slab, one Rapier collider and one mesh; a thousand
slabs are a thousand meshes and, on a slope, a thousand lips between them. Instead:

- the scene carries `roads: [{ kind, width, points: [[x, z], …] }]`, polylines clipped to
  the bounds, ~30 KB;
- the client builds ONE ribbon mesh: each polyline offset by half its width on either
  side with mitred joins, subdivided so no edge is longer than 5 m, every vertex at
  `ground(x, z) + rules.roads.lift` (3 cm), one merged `BufferGeometry`, one material with
  `polygonOffset` so it sits on the terrain without fighting it. One draw call, no colliders;
- the car drives on the heightfield, which the AHN terrain model already shapes to the
  road (a DTM is the ground, roads included), with the terrain's own friction, which is
  the road's friction today.

Colours per kind live in `rules.roads.colours`. Kerbs and pavements are the later step
the brief names. Flat worlds keep their slab; `roads` is `[]` for them and the ribbon
mesh is not built.

### 7. Spawns

`spawns` already holds a list; the client uses the first. `arena_controller.js` reads
`?spawn=<index>` the way it reads `?vehicle=` and the engine spawns and respawns at that
entry, falling back to the first. The church is a kilometre from the estate, and a test
about the church should not begin with a minute's drive.

### 8. Terrain from AHN

`Game::Terrain::TileBuilder.encode(frame:, tx:, tz:) { |x, z| … }` was written for
exactly this: the block converts game `(x, z)` to RD with `frame.to_source`, reads the
height there, and returns `height − origin_z`. The height comes from the AHN digital
terrain model (`dtm_05m`, PDOK, CC0), which the sibling app has already fetched over WCS
and resampled to 10 m into `~/Developer/mijnstreek/data/dem.raw` (Float32, little-endian,
rows north→south, origin 165500/423500, 5050 × 11850, covering both islands). The importer
reads that file with bilinear interpolation of the four nearest samples — our grid points
fall on its pixel edges — through a small `Game::Import::Dem` that takes a path and a
geotransform and knows nothing of the sibling. Fetching from PDOK ourselves is the
documented alternative (`dem.rake` is the reference) for a machine without the file; the
result is the same nine tiles, and they are checked in either way.

A row's `y` is the mean ground under the corners of its dwellings' rectangle
(`Hills.base_height` does this for a rectangle today and moves to a place a sampler can
share). A shed cluster's `y` is its own. The 1.7% slope puts a row of four's ends about
15 cm into and out of the ground, as `hills` already does for its house.

### 9. The importer, and what it writes

`bin/rails geleen:import` (`lib/tasks/geleen.rake`) is reproducible and touches nothing
at runtime: it reads, it writes fixtures, and the app never talks to PostGIS or the DEM.

Pipeline, each stage a PORO under `Game::Import` with a unit test on a small fixture
extract, ported from the spike's `build_world.rb` and `classify.rb`:

1. **Query** PostGIS read-only (`PGOPTIONS=-c default_transaction_read_only=on`, through
   `psql`, no new gem) with the spike's SQL: parts with mesh-derived eaves and ridge
   (roof faces assigned to parts by majority footprint overlap), adjacency, DBSCAN
   clusters of main parts (eps 0.3 m), buffered unions (±0.2 m, so a hairline gap does
   not split a row), oriented envelopes, roads clipped to the bounds.
2. **Classify** each `Pand`: shed, house, apartments, hall, church, by the spike's rules,
   with the OSM `kind` as an override where it names a landmark.
3. **Frame** each cluster: axis from the envelope's edges, direction from the dwelling
   centroids, street side from the nearer road or the side without annexes.
4. **Band and slice**: the depth every dwelling shares, party lines at the midpoints
   between neighbours, `eaves` the maximum and `ridge` the median over the dwellings,
   `storeys = round(eaves / 2.8)`, `storey_height = eaves / storeys`, roof `gable` when
   `ridge − eaves > 0.8` else `flat`.
5. **Boxes**: every other part as a ring in the row frame with its own eaves and ridge,
   `pyramid` on a part whose height is more than twice the square root of its area,
   `gable` when the rise exceeds 1.5 m, `flat` otherwise; sheds as solid boxes.
6. **Write** `test/fixtures/worlds/geleen.yml`, `test/fixtures/world_objects/geleen.yml`
   and `test/fixtures/terrain_tiles/geleen.yml`. Rails reads a table's fixtures from
   `<table>.yml` and from every file under `<table>/`, so the hand-written worlds stay in
   their files and the generated one sits beside them. Each generated file opens with the
   attribution — 3DBAG (TU Delft, CC BY 4.0), BAG (Kadaster), AHN (PDOK, CC0), OpenStreetMap
   (ODbL) — the import date and the parameters (centres, radii, cell sizes). `piece_count`
   and `storey_count` are computed by generating each recipe and written down, as the
   hand-made fixtures do.

`db/seeds.rb` is unchanged: it loads the fixture sets, and a fixture set now includes its
directory. Re-running the import rewrites three files and nothing else; the diff is the
review.

### 10. Debug overlay

The plates already show `category`, name and `pands`. The row recipe carries both, so an
imported building says `HOUSE row-12 053076 … 053079 (4)` and a church says its `Pand`.

## Data flow

```
PostGIS (read-only) ─┐
                     ├─ geleen:import ─► test/fixtures/{worlds,world_objects,terrain_tiles}/geleen.yml
dem.raw (AHN) ───────┘                          │
                                                ▼ db/seeds.rb / fixtures
                                       World, WorldObject(recipe kind row), TerrainTile rows
                                                │
                                Spec.for(world) │ Generator.call(recipe) → Row generator → SurfaceSet (bays)
                                                ▼
                       <script type="application/json"> arena.buildings[], arena.roads[], arena.terrain
                                                │
              client: Buildings (pieces, plates) · RoadsView (one ribbon) · Terrain (9 tiles over HTTP)
                                                │
        damage {hits ≤ cap per message} ──────► ArenaChannel → MatchState.apply_batch → Collapse per bay
        breaks {broken, collapses: [id, storey, bay]} ◄──────────────── error "batch_truncated" if ever
```

## Edge cases

- **A row cut by the island's edge** gets a gable where a party wall stood. Accepted; the
  cut is a parameter of the import, not of the row.
- **A dwelling whose ring reaches past the shared band** by more than a metre gets the
  excess as a full-height box. In this window every such case was a 30 cm sliver along
  an annex and is dropped by the band; the path exists for the estate that has real ones.
- **Two boxes meeting** generate their shared wall once, from the first; **a box against
  the row** generates no wall there. Both are per-edge tests on the ring in the row frame.
- **A box that spans two dwellings** is given the bay of the one it overlaps most, by the
  importer, and that choice is in the recipe for good.
- **A bay with no load-bearing surface at some storey** (a single-storey box beside a
  two-storey dwelling) is only evaluated for the storeys it has.
- **A collapse over the slab budget** falls back to breaking where it stands, as today;
  the per-bay reveal counts landed slabs of that bay, and a bay with no slabs reveals its
  wreckage at once.
- **Legacy `collapsed_from` rows** migrate to `collapsed: { "0": n }`; a match from before
  the migration rejoins with its collapse intact.
- **A batch over the cap** from an old client is applied to the cap and answered with an
  error; nothing is dropped silently.
- **The DEM has no data** at a point (the file is filled, but the guard stays): the
  importer raises rather than writing a hole into a tile.
- **Roads outside every tile** sample the terrain fallback of 0 and would hang in the
  air; they are clipped to the bounds, which lie inside the tiles.

## Testing

**Ruby, no browser.**
- `row_test.rb`: the worked example from a real pair pins kinds, offsets, bays, `between`,
  `bays` on rubble and `piece_count`; the order test; rubble last; every cell round trips;
  rotation preserves indices and materials and rotates only `o`/`u`/`v`/`n`; a recipe
  with no dwellings and two boxes; a pyramid's four planes clip to triangles; a box
  against the row drops its junction edge; two boxes share one wall; a two-column face
  gets no door.
- `generator_test.rb` and `world_summary_test.rb` unchanged and green: the four worlds'
  `piece_count`s are the proof the `building` path did not move.
- `collapse_test.rb`: the spike's scenarios as assertions — one dwelling front and back
  gone collapses that bay and no other; a party wall gone weakens both neighbours; the
  nave alone collapses the nave and leaves the tower; a `building` recipe behaves as
  before; `collapsed` is monotone per bay.
- `match_state_test.rb`: a batch over the cap applies the cap and reports truncation;
  `state_for` carries `collapsed`; rehydration from a migrated row.
- `material_test.rb` / parity: `health_for` rounds, and rounds the same on both sides.
- `import/*_test.rb`: classifier on a labelled extract; clustering and framing on the
  spike's exported window (checked in under `test/fixtures/files/geleen/` as the
  importer's own test input); `Dem` bilinear sampling against a hand-made grid.
- `frame_test.rb`: `to_game(186330, 332234) == [1330, -2234]`, already implied.

**Browser.**
- `geleen_test.rb`: boots the world, ~90 buildings, no severe console errors, terrain
  probe agrees at both islands, `?spawn=1` lands beside the church, roads are one mesh
  with as many vertices as the polylines imply, a car driven along Muldershof stays
  grounded.
- `bays_test.rb` (its own match): front and back of one dwelling of a row of four broken
  through `__arenaDamagePiece` → the server condemns that bay only, `__arenaBays` shows it,
  the neighbour's standing count is unchanged, the neighbour's rubble stays dormant; a
  church nave's ground storey → the nave falls and the tower stands.
- `damage_batching_test.rb`: 1,300 pieces broken in one frame → server count equals
  client count, no `batch_truncated`.
- `building_labels_test.rb` gains the imported case: a row's plate reads its `Pand` ids.
- `shots_test.rb` gains the estate row from the kerb and the church from the road, for
  judging by eye.

The system suite runs at `quality: "low"`, serially, under the machine lock, as always;
`bin/rails test` stays at 0 failures after every task.

## Migration notes

- One migration: add `object_damages.collapsed` (JSON, default `{}`), backfill
  `{ "0" => collapsed_from }` where set, drop `collapsed_from`. The dev database keeps its
  matches.
- `Game::Building::Surface` gains `bay`, `between`, `bays`, `rotated(yaw)`; its spec gains
  `bay` (omitted when 0), `between`, `bays` — the four worlds' specs gain no key.
- `Game::Scene` gains `roads`; `Game::Spec.default_rules` gains `roads: { lift, colours }`
  and `damage.max_hits_per_batch`.
- `Game::Building::Generator` dispatches on `kind`; `Game::Building::Row` is new;
  `Game::Import::{Dem, Classifier, Clusters, RowFrame, Massing, Fixtures}` are new and used
  only by the rake task and their tests.
- `CLAUDE.md`: the fifth world, the `row` recipe and its order, bays, the batch rule, the
  road ribbons, the import command, the new hooks.

## Out of scope

- **Appearance**: procedural surface detail, palettes per building, garage doors, window
  frames, gardens (from BGT `land_covers`, which the sibling database also holds: 2,805
  green areas, 1,070 yards and 276 hedges inside these bounds), trees (4,104). The next
  design; it can be judged on this world.
- **Pavements and kerbs.** Later, as the brief says.
- **Streaming**: the corridor between the islands, or any wider window.
- **The contrast window** with the tower block: the next world, once apartments-as-
  parameters is proven.
- **Rubble skirt scaling** for sheds; noted in the spike, left as it is.
