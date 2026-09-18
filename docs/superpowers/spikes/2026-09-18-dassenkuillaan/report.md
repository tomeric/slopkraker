# Dassenkuillaan spike: procedural buildings from 3DBAG shapes

Date: 2026-09-18
Status: **spike report, nothing built.** Everything under this folder is throwaway evidence:
SQL that was run read-only against the sibling database, Ruby that generated the buildings
outside the app, and the pictures. No app code, fixture or migration changed. The next step
is the design doc; the questions it has to settle are listed at the end.

The brief asked for four things before any importer is written: classify all of Geleen-Noord
and score it against OSM, cluster the 54 `Pand` in the 50 m window by adjacency, run them
through a generator offline, and report the category table, the accuracy, the clustering,
the budget and pictures. All four are below. The short version:

- **A terrace is one building.** Clustering attached main parts gives 14 dwelling clusters
  (two rows of four, eleven semi-detached pairs, one detached house) and 16 shed clusters.
  Generated as rows, they come out with one ridge, one roof, party walls once, gables only at
  the ends. See `shots/10-door-close.png` and `shots/19-row12-raking-from-the-kerb.png`.
- **One generator, categories as parameter sets.** The row generator — a shared depth band
  sliced by party walls, plus one-storey "boxes" for annexes — also generates sheds (zero
  dwellings, solid boxes) and churches (zero dwellings, one box per 3DBAG part with its own
  eaves, ridge and roof). The only genuinely new surface arrangement any category needed is a
  **pyramid roof** on a slender part. Everything else was a parameter.
- **Budget: 54 `Pand` cost 18,404 pieces, 357 KB of inline spec and 41,050 instances at 1 m
  cells**, against the street's 7,205 / 103 KB / 20,140 for twelve houses. Bytes scale with
  surfaces (691 of them at ~516 B each), not cells; rounding the floats and hoisting the
  per-material stats out of each surface gets the spec to 61%. Rubble chunks are 60% of the
  instances. Draw calls: 22, fewer than the street's 32.
- **The collapse rule does not fit rows as one building.** Gutting one dwelling of a row of
  four (front, back and both party walls) leaves 69% of the ground floor's support and the row
  stands; a semi-detached pair cannot be brought down by driving through both houses front to
  back (76% left). Per-dwelling bays with shared party walls are the recommendation, and it is
  a protocol change.
- **Stay at 50 m.** The 100 m window is ~1.1 MB of spec before the byte levers, and that is
  the streaming job.

## 1. The data, measured

The window is 50 m around RD (186330, 332234), which lands at game (1330, −2234) under
`Frame.mijnstreek`; the point itself is on **Muldershof**, a cul-de-sac off Dassenkuillaan
(the named street is 61 m away). Everything within reach is a 1987–1992 estate of two-storey
brick terraces and semis with single-storey rear extensions and brick bike sheds.

| | |
|---|---|
| 3DBAG parts / `Pand` intersecting the circle | 75 / 54 (48 by centroid) |
| dwellings / sheds and garages | 31 / 23 |
| main dwelling part | 48–53 m², 5.5–6.3 m wide, 8.6–9.3 m deep, rectangularity 0.74–1.00 |
| annexes (rear and side extensions, one garage) | 21 parts, 19–66 m², 2.6–3.8 m tall |
| sheds | 23 parts, 2.9–21 m², 2.0–3.6 m tall, `horizontal` |
| eaves / ridge of the dwellings (from LoD2.2, see below) | 5.1–6.0 m / 8.4–9.3 m |
| `b3_bouwlagen` (`levels`) on every dwelling | **3**, on all 28 — it counts the attic |
| ground (`b3_h_maaiveld`) | 63.8–65.8 m NAP in the window, 62.5–66.4 within 100 m |
| slope | 1.7% falling to the north, 0.5% rising to the east |
| OSM labels | 28 `house`, 20 `yes` |
| neighbours within 30 cm, 48 `Pand` by centroid | 0: 8, 1: 20, 2: 18, 3: 2 |
| …among the 28 dwellings | 1: 11, 2: 15, 3: 2 — **every house is attached** |

Three findings shape the generator:

**Eaves and ridge come out of the LoD2.2 mesh, per part.** `buildings.height` is the 70th
percentile roof height, which for a gable sits at `eaves + 0.7 × rise` and says nothing on its
own. Every one of the 54 `Pand` has a `building_meshes` row; taking the roof-labelled faces
whose 2D footprint lies more than half inside a part gives that part's eaves (minimum Z) and
ridge (maximum Z). Taking the minimum over the whole `Pand` instead is wrong: it returns the
flat roof of the rear extension (2.6–3.0 m), which is how the first query read "eaves 2.7 m"
for a two-storey house.

**`levels` counts the attic.** Every dwelling reads 3 with an eaves height of 5.7 m. Storeys
must be derived: `round(eaves / 2.8)`, then `storey_height = eaves / storeys`, so the walls
end exactly where the roof begins (2.57–2.99 m per storey here). `levels` is `NULL` on 101 of
the 118 OSM-labelled apartment `Pand` in the neighbourhood and on every shed.

**The parts really are the massing.** 827 of Geleen-Noord's 2,559 `Pand` have two parts (main
house plus extension, 4.9 m apart in height on average), 85 have three, and the two reference
churches have nine and eight. Four dwellings in the window with rectangularity 0.74–0.83 turned
out not to be L-shaped at all: their polygon carries a 30 cm sliver along a neighbouring annex
(`[[3.1, 0.0], [2.94, 11.92], [3.22, 8.98], [8.8, 8.94], [8.73, 0.0]]` in the row frame).
Snapping to the depth the row shares drops the sliver. **No dwelling in this window needs a
concave footprint.**

## 2. Classification, scored

Signals per `Pand`, all from one SQL pass (`sql/hood_pand.sql`): footprint area, area of the
largest part, tallest part, rectangularity of the union and of the main part (area over
oriented envelope), simplified vertex count, slenderness (`height / √area` of the most
slender part), `roof_type`, `levels`, year, neighbour count within 30 cm, and the OSM `kind`
of the most-overlapping OSM building. The rules are twenty lines (`scripts/classify.rb`); the
thresholds for house-versus-apartments were swept against the labels.

Geleen-Noord, 2,559 `Pand` by centroid, scored on the 1,875 with an OSM label other than `yes`:

| category | `Pand` | share | avg m² | avg h | labelled | agree | accuracy | generator |
|---|---|---|---|---|---|---|---|---|
| house (rows, pairs, detached) | 1,336 | 52% | 97 | 7.7 m | 1,287 | 1,227 | **95%** | row: dwellings in a depth band, party walls, one roof, boxes for annexes |
| shed / garage | 1,084 | 42% | 16 | 2.8 m | 482 | 478 | **99%** | same code, zero dwellings: solid one-storey flat boxes sharing walls |
| apartments | 128 | 5% | 608 | 11.6 m | 102 | 67 | 65% | parameters: flat roof, `storeys = round(eaves / 3.0)`, partitions every N metres |
| hall (industrial, retail, school) | 8 | | 858 | 7.8 m | 3 | 2 | 66% | parameters: big flat box, coarse cell |
| church | 3 | | 1,970 | 19.2 m | 1 | 0 | — | parts as boxes, pyramid roof on the slender one |

Where it goes wrong, and why it is acceptable:

- **Apartments are the weak class (65%).** Fifty labelled apartment `Pand` were called houses:
  three-storey walk-ups of 130–220 m² at 8.4–9.4 m are the same height as a two-storey house
  with an attic, and `levels` is `NULL` on 86% of them. Twenty-five houses were called
  apartments (large, 9.5 m+). The best split found was `area > 120 m² and height > 9.5 m, or
  levels ≥ 4`; every other threshold in the sweep was worse. Since apartments collapsed into
  parameters anyway, a misclassified one costs a flat roof where a gable belonged.
- **Churches need a tower.** Over the 13 OSM churches within 4 km, the rule (a part with
  slenderness > 2, footprint > 300 m², union rectangularity < 0.75) finds **9**. The four it
  misses are box-shaped modern churches (rectangularity 0.76–0.92) or towerless ones, which
  no geometry separates from a hall. It finds 0 of 6 chapels (22–74 m² boxes, or a 1,070 m²
  hospital chapel). It also fires on the apartment cluster with the 34 m tower block. **Use
  the OSM `kind` as an override for landmarks** — it labels 16 churches in the whole database,
  and geometry is for the 99% it cannot name.
- Sheds are essentially solved: 4 of 486 wrong, all garages OSM called `house`.

For the two windows: the 50 m window is 28 houses and 20 sheds; the contrast window (120 m
around 186100, 331420) is 26 houses, 12 sheds and 7 apartment `Pand` by centroid.

**What collapsed into parameters, and why.** A category earns a generator only if it produces
different surfaces. Sheds are boxes with no openings and no interior — the annex path with
`solid: true`. Apartments are the row path with a flat roof, more storeys and (later) a
partition rhythm; same surface kinds, more of them. Halls are one big flat box at a 2 m cell.
Churches are the box path run once per part with per-part heights, which the annexes already
needed; the pyramid is the one new roof kind (four triangles clipped with void exactly as a
gable end is — `Roof.clip` already draws that triangle). So the design has **two recipe
kinds**: the existing `building` (one ring, untouched, for the four worlds) and `row`.

## 3. Adjacency clustering → rows

`ST_ClusterDBSCAN(eps 0.3, minpoints 1)` over the **main** part of each `Pand` (the largest
part taller than 4 m, else the largest) gives 30 clusters in the window (`sql/rows.sql`):

| cluster kind | count | sizes |
|---|---|---|
| dwelling rows | 14 | two rows of 4, eleven pairs, one single |
| shed huddles | 16 | ten singles, five twins, one triple |

The 100 m neighbour table reproduces the brief's (20/75/72/5 against 22/75/70/5), so the
adjacency method agrees with whatever produced the brief.

Each cluster gets a **row frame**: local x along the row, local z across it, the street at
z = 0, origin at a corner so every local coordinate is positive, and a yaw. Three rules,
each learned the hard way:

- **The axis comes from the envelope's edges, the direction from the centroids.** Taking the
  angle between the two dwelling centroids tilted two pairs by 14° because their depths
  differ; taking the envelope's long side alone fails on a pair attached along its long
  walls (cluster 4, envelope nearly square). So: edge direction from `ST_OrientedEnvelope`,
  and of the two perpendicular candidates, the one the centroids spread along.
- **The depth band is what every dwelling shares**: deepest front to shallowest back. The
  median stretched a rectangular house by 1.5 m to meet its sliver-carrying neighbour. A
  dwelling that genuinely reaches past the band would get the excess as a full-height annex
  (the half-plane clip is written and tested); in this window it never fires, see §1.
- **The street side** is the long side nearer a road when the two differ by more than 3 m
  (12 of 14 rows), else the side the annexes are not on. One detached house (row-20, garage
  between it and the road) is debatable. Doors go on that side. Rows in `shots/00-plan.png`
  carry a line-and-dot marker on the side chosen.

Snapping costs: dwelling boxes deviate from the band by ≤ 0.2 m in 10 of 14 rows; the other
four are the sliver cases above. Eaves within a row spread 0.1–0.5 m (1.1–1.5 m where a
sliver dragged an annex roof into a main part's faces); the row takes the **maximum** eaves
and the **median** ridge. Ridges spread ≤ 0.4 m except row-9 (1.3 m, one house re-roofed).

The union footprint for rubble is `ST_Union` of all parts of the row's `Pand`, **buffered out
0.2 m and back**: without that, a hairline gap between two 3DBAG parts split a row of four into
two polygons and the rubble grid covered half the row.

## 4. The generator prototype (`scripts/terrace.rb`)

Built entirely from the existing modules: `Walls.wall` for every wall, `Openings` for windows
and doors, `Interior.build` per dwelling for decks and partition, `Roof.build` over the row's
rectangle, `Rubble.build` over the union ring. The only new geometry is the clipped flat deck
(a grid over a ring's box, void outside the ring — `Rubble`'s own trick), the pyramid, and
edge deduplication.

**Order, which the design must pin as the contract:**

1. per dwelling in x order: front wall per storey, then back wall per storey
2. the two end walls of the row
3. party walls between neighbours (brick, no openings)
4. per dwelling: decks and partition (`Interior.build`)
5. the roof over the whole row (two planes plus two gable ends, or one flat deck)
6. boxes (annexes, sheds, church parts) in recipe order: kept walls per storey, decks, roof
7. rubble, last

**Rotation is done in Ruby.** Every surface is generated in the row frame and then its
origin, `u` and `v` are rotated by the yaw before the `SurfaceSet` assigns offsets. The client
already reads `o`, `u`, `v`, `n` per surface and ignores `yaw`, so it needed no change: the
whole estate, rotated 46° off the RD grid, rendered correctly first time, heaps included.
`piece_index` arithmetic, `Blocks`, `chunking.js`, `Damage::Collapse` were all untouched.

**Boxes generate each wall once.** An edge is skipped when both ends lie on or inside the
row's rectangle (an annex standing against the house), or inside an earlier, larger box (a
chapel against a nave), or when it is coincident with an already-kept edge (two annexes
sharing a wall, twin sheds). A box's roof and floor decks are void where they would lie inside
the row or a bigger box. Sheds are solid: at a 1 m cell a 2.2 m shed front is two columns,
`Openings` makes the door three wide, and the whole face became a door under a full-width
steel lintel (`shots/12` before, `shots/17-sheds-solid.png` after).

**Cell size** was 1.0 m for everything, as the `targets` house. A storey of 2.86 m is three
rows, so windows sit a course up, as intended.

Pictures, all from the driver's seat at the suite's 1400×900 (`scripts/dassenkuil_shots_test.rb`):

| shot | what it shows |
|---|---|
| `00-plan.png` | the window in plan: parts, generated rows with party walls and street side, annex rings, roads |
| `10-door-close.png` | the row of four from 5 m: one roof, four doors, no seams. The black band over a door is the steel lintel, which renders dark in the existing house too |
| `13-row12-from-the-kerb.png`, `19-row12-raking-from-the-kerb.png` | the same row from the road, straight on and raking |
| `11-annex-close.png` | the back of a pair: flat-roofed extensions against two-storey houses |
| `14-row9-end-and-garage.png` | a row end with its garage box |
| `15-row18-front.png` | two pairs side by side |
| `17-sheds-solid.png` | twin bike sheds, one shared wall |
| `20-church-047987-front.png`, `21`, `22`, `23-church-057078-high.png` | the two reference churches from their parts: nave gable over the cross-shaped ring, pyramid spire on the tower |

The church test the brief asked for first — "one pass per part, massed together, without
teaching the roof about concave rings" — passes at the vibe level: the Lindenheuvel church
(`NL.IMBAG.Pand.1883100000057078`, nave 758 m² with rectangularity 0.59) reads as a church
from the road and from above. The bbox gable over the cross-shaped nave overhangs the
transept notches; from 15 m/s nobody will see it. What does show: a six-storey tower with a
window every other column on every storey. Openings want a per-category density.

## 5. Budget

Measured by generating every recipe with the spike generator and counting exactly what the
client counts (`Building.countMaterials`: every non-void cell, plus 20 chunks per rubble
heap). Draw calls read from `__arenaDraws()` in headless Chrome; note that three.js counts
only what the frustum kept, so the number depends on where the car is parked.

| world | `Pand` | objects | surfaces | pieces | spec bytes | instances | draws | boot |
|---|---|---|---|---|---|---|---|---|
| `street` (12 detached houses) | 12 | 12 | 237 | 7,205 | 103 KB | 20,140 | 32 | |
| window, 1.0 m cell | 54 | 30 | 691 | **18,404** | **357 KB** | **41,050** | **22** (+23 for 86 road slabs) | 1.3–3.3 s |
| window, 1.5 m cell | 54 | 30 | 691 | 9,407 | 329 KB | 32,737 | | |
| of which 14 dwelling rows | 31 | 14 | | 17,260 | 291 KB | | | |
| of which 16 shed clusters | 23 | 16 | | 1,370 | 63 KB | | | |
| Lindenheuvel church, 1.0 m | 1 | 1 | 206 | 11,441 | 131 KB | | | |
| same, 2.0 m | 1 | 1 | 206 | 3,264 | 102 KB | | | |

What the numbers say:

- **Per dwelling with its annexes: 9.4 KB and ~560 pieces**, against the street's 8.6 KB and
  600 pieces per detached house. Terraces are not cheaper per dwelling: party walls are shared
  but every dwelling still has its own front, back, decks, partitions and annexes.
- **Bytes follow surfaces, not cells.** Halving the cell count (1.5 m) saved 8% of the bytes.
  A surface costs ~516 B: rotated `o`/`u`/`v`/`n` printed at 16 digits, `hp`/`kg`/`str` maps
  repeated per surface (247 B of a 650 B wall), `blocks`, patches. Measured on the window:
  rounding floats (4 decimals on vectors, 3 on metres, 2 on health, whole kilograms) gives
  **77%**; also hoisting `hp`/`kg`/`str` to one table per (material, cell area, thickness)
  gives **61%**, 215 KB. Both are `Surface#to_spec` changes with a parity test to prove them.
- **Rubble is 60% of the instances**: 1,233 heaps × 20 chunks. The 3 m skirt is sized for a
  house; a 2 m shed gets a 4×4 grid and 6–16 heaps of wreckage. The skirt should scale with
  the building (it decides `piece_count`, so it is a Ruby constant with a fixture cost).
- **Sheds are 46 B per piece** against 17 for rows: seven surfaces for four square metres.
- Draw calls did what the architecture promised: 30 buildings, 22 draws.
- **A church at a 1 m cell costs one and a half streets.** Cell size wants to be a category
  parameter: 1.0 for dwellings, 2.0 for churches and halls.

**Window growth.** At this rate the 75 m window (109 `Pand`) is ~720 KB and 37 k pieces, the
100 m window (172 `Pand`) ~1.1 MB and 59 k pieces before the byte levers, ~440 KB and ~700 KB
after. The 50 m window is already 3.5× the street's bytes. **Recommendation: build the 50 m
window first, land the two byte levers, and then decide whether 75 m fits without streaming.
100 m does not; that is the streaming job.** The contrast window (71 `Pand`, tower block,
parking structure) roughly doubles the budget and exercises the apartments path, which is
parameters; I would make it the second world rather than fold it into this one.

## 6. Destruction: what a row does to the collapse rule

Every claim about scale in `CLAUDE.md` was made against detached houses; the collapse rule is
calibrated on a 12×15 m one whose front and back walls are a large share of its ground floor.
In a terrace the party walls are the long walls. Running `Game::Damage::Collapse.evaluate`
against the generated rows (`threshold 0.40`, `safety_factor 1.6`, so a storey fails when
less than 62.5% of its support is left):

| scenario | row of four | semi-detached pair |
|---|---|---|
| one dwelling: front + back walls gone | 89% left, stands | 88%, stands |
| one dwelling: front + back + both party walls | 69%, stands | 77%, stands |
| end dwelling: front + back + end wall + party wall | 71%, stands | 68%, stands |
| every front wall | 79%, stands | 89%, stands |
| every front and back wall | **57%, collapses** | 76%, **stands** |

So with the row as the collapse unit, one house can be gutted to its party walls and nothing
falls, and a pair cannot be brought down at all without demolishing a party or end wall. That
is structurally honest and, for a game about driving through houses, wrong.

**Decision: the row is one object, and collapse is per dwelling bay.** Each surface carries a
bay index (the dwelling it belongs to; party walls belong to both, roof planes to none until
they are split per bay); the rule evaluates each bay with its own front, back, decks and
partition plus the shared party walls as support, and a condemned bay fells its own surfaces
but **never a party wall** — so the neighbour's support is unchanged and a row does not
domino. In that model "front + back gone" leaves ~60% and the bay comes down, which is what
driving through a house should do. Costs: `[object_id, from_storey]` becomes
`[object_id, from_storey, bay]` on the wire, `collapsed_from` becomes per bay in
`object_damages`, the client's expansion filters by bay, and rubble reveals per bay (the row's
rubble grid is split into one surface per bay, appended last in bay order, so `pile_indices`
and `revealed_count` stay as they are). This is the largest single item for the design doc.
The alternative — one world object per dwelling with the party wall owned by one of them —
was rejected: it puts the row's one roof back into per-house pieces, doubles nothing but
leaves the seam problem this project already fought.

## 7. Terrain and the frame

- `Frame.mijnstreek` as is: Dassenkuillaan lands at game (1330, −2234), north is −z, and the
  plan view checks against the map.
- **`origin_z = 60.0` for this world.** Ground in the window is 63.8–65.8 m NAP, so the estate
  stands at y ≈ 4–6, spawns are `ground + 2`, and the bounds walls' "10 m below the lowest
  ground" still holds. Geleen-Noord as a whole is 51–68 m NAP, y −9 to +8, if the world ever
  grows. `HeightsCodec` centres each tile on its own `base_cm`, so this is about readable
  numbers, not precision.
- **One 500 m tile covers the window and a 300 m bounds box**: tile (2, −5) in
  `Frame.mijnstreek`, 51×51 samples, 5.2 KB. AHN `dtm_05m` via PDOK WCS resampled to 10 m, as
  `dem.rake` does in the sibling.
- **One `y` per row**, the mean ground under the row's corners (`Hills.base_height` already
  does this for a rectangle). The slope is 1.7%: a row of four spans 23 m along the contour
  direction at about 45°, so its ends differ by ~0.3 m, buried 15 cm one end and clear 15 cm
  the other. Sheds and annexes take the row's `y`; a shed cluster its own.

## 8. How the data crosses over

**Decision: an import task reads PostGIS read-only and PDOK once, and writes fixtures that are
checked in.** `test/fixtures/` stays the single definition of every world, seeds stay
`create_fixtures`, tests and the browser cannot disagree, and the repo has no runtime
dependency on the sibling database. The output is small: 30 recipes of ~1 KB each and one
5 KB tile as a `!!binary` blob. Attribution goes in the fixture file header and the task
(3DBAG CC BY 4.0, TU Delft; AHN, PDOK). The task lives in this repo, runs with
`PGOPTIONS="-c default_transaction_read_only=on"`, and needs `psql` on the path or the `pg`
gem in the development group. The alternatives: querying PostGIS at request time couples
every boot to a database this app does not own; re-fetching 3DBAG tiles from `data.3dbag.nl`
means a 13 GB LoD2.2 download to get eaves heights the sibling already holds.

## 9. Constraints and gotchas found

- **Hairline gaps.** `ST_Union` of a row's parts split one row of four into two polygons.
  Buffer out 0.2 m and back with `join=mitre` before simplifying.
- **The 70th percentile height is not the eaves**, and the `Pand`-level roof minimum is the
  extension's roof. Assign LoD2.2 roof faces to parts by majority footprint overlap.
- **`multiple horizontal`** (156 in the neighbourhood) is a `Pand` whose parts have different
  flat roofs; per-part generation handles it with no rule. `unknown` (6): decide by rise.
- `roof_type` maps: `slanted` with `ridge − eaves > 0.8` → gable, else flat; `horizontal` →
  flat. Extensions labelled `slanted` at `Pand` level are flat in the mesh.
- **Rows longer than the chunk.** `radius` must stay under 125 m; the longest row here is
  23 m plus annexes (radius 32 m). A Dutch row of twelve is 65–70 m; fine. Rows cut by the
  window edge get a gable where a party wall stood.
- **Draw calls are view-dependent** (frustum culling), so `__arenaDraws` needs a fixed pose.
- **Two piece hooks per row.** `__arenaBuildingStanding` and friends address the row; a test
  about one dwelling will want a bay filter.
- The running dev server is a puma on **port 3000** (pid 81079, 23 h old, started from a
  shell), while `.dev-port` says 3100 and nothing listens there; `bin/dev` refuses to start a
  second one because of `tmp/pids/server.pid`. I left it alone.

## 10. What the design doc has to settle

1. The `row` recipe: fields (yaw, cell, band, storeys, eaves, ridge, roof, dwellings,
   boxes with eaves/ridge/storeys/roof/solid, footprint, category), the pinned order above,
   and a worked example from a real row with its offsets and `piece_count`.
2. Bays: tagging, the per-bay collapse evaluation with shared party walls, the wire change,
   `collapsed_from` per bay, rubble split per bay.
3. Rotation in `Surface`/`SurfaceSet` (a `rotated(yaw)` that the row generator applies), and
   the float rounding in `to_spec` behind the parity test.
4. The pyramid roof kind, and openings density and cell size as category parameters.
5. The importer: cluster → frame → band → boxes exactly as `scripts/build_world.rb`, the
   category from `scripts/classify.rb` with OSM overrides, the LoD2.2 eaves query, the AHN
   tile, `y` per row, and the fixture it writes.
6. The rubble skirt scaling with the building, or accepting shed wreckage.
7. Which world: `geleen` at 50 m first; the contrast window second.

## Reproducing

- `sql/*.sql` were run with `PGOPTIONS="-c default_transaction_read_only=on" psql -d
  mijnstreek_drive_development -Atq -f` into JSON. `hood_pand.sql` is the classifier's input,
  `window.sql` the parts with mesh-derived eaves and ridge, `rows.sql` the DBSCAN clusters,
  `church_features.sql` the churches within 4 km.
- `scripts/classify.rb hood_pand.json` prints the category table and confusion matrix.
- `bin/rails runner scripts/build_world.rb` (with `data/` beside `scripts/`) builds recipes,
  generates and measures; `CELL=1.5` for the coarser grid; `build_church.rb` the same for the
  churches; `plan_svg.py` the plan.
- `bin/rails test scripts/dassenkuil_shots_test.rb` with `QUALITY=high SHOTS_LIST=...` boots
  the recipes inside the test transaction with `WorldObject#surface_set` prepended, and saves
  frames. It takes the machine-wide system-test lock like any system test.
- `recipes-cell-1.0.json` and `recipes-church-cell-1.0.json` are the generated recipes, so
  the pictures can be re-taken without the database.
