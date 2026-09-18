# How buildings look: surface detail, palettes, openings, gardens

Date: 2026-09-18
Status: designed. Follows `2026-09-18-geleen-two-islands-design.md`, which put real buildings
in the world and changed nothing about how a wall is drawn. This document is about the
drawing, and it is judged on the `geleen` world from the driver's seat.

## Why

Every piece in every world is a flat-coloured box: one `MeshStandardMaterial` per material,
its colour from `Game::Materials`, darkened per instance as it takes damage. At 15 m/s that
reads as a model of an estate, not an estate. Nothing says brick, nothing says tile, every
house is the same brown, and a door is a dark rectangle three metres wide. The sky is night.

The brief for this phase: procedural surface detail — individual bricks, individual roof
tiles, depth in the surface; palettes so buildings differ from one another; openings that
mean something — a garage where a garage would be, doors and windows sized like doors and
windows; and gardens where the road data says the gardens are. Pavements are a later step.

Three constraints from the rest of the codebase shape every decision below:

- **Every tuning number lives in Ruby and ships in the spec.** Brick size, joint width,
  colour variation, palette colours, window rhythm: all of it is data the client receives.
- **Draw calls track materials, never buildings**, and an `InstancedMesh` is allocated once
  and cannot grow. Whatever makes a brick look like a brick has to happen inside the one
  material a pool already has, per instance, with no new meshes.
- **Piece indices are the contract.** Anything that adds or moves a surface in the `row`
  recipe regenerates the `geleen` fixtures (they are generated, so that is one command) and
  must leave the four hand-made worlds byte-identical.

## Decisions

### 1. What a material looks like is a `Material` attribute

`Game::Material` gains a `look`, shipped in `materials[*].look`:

```ruby
brick: Material.new(
  …,
  look: { pattern: "brick", unit: [ 0.21, 0.065 ], joint: 0.012, joint_shade: 0.55,
          variation: 0.10, relief: 0.6, base: "#c9a58a" }
)
```

| pattern | units | what it draws |
|---|---|---|
| `brick` | brick length × course height, joint width | running bond, half-brick offset per course, mortar recessed |
| `tiles` | tile width × course height | overlapping courses, each course's lower edge dropped in relief, a shadow line under it |
| `planks` | plank width | boards along the surface's long axis with a dark seam and grain noise |
| `plaster` | — | flat, a little low-frequency noise |
| `concrete` | — | speckle, slight variation, no relief |
| `glass` | frame width | a transparent pane inside an opaque frame in the palette's frame colour |
| `metal` | — | flat, reflective (see §7) |
| `dust` | — | rubble's lump; already a shape, gets a speckle only |

`base` is the material's albedo in **value space**: light, nearly neutral, with the hue left
to the palette (§4). `variation` is the per-unit lightness jitter (each brick a little
different, seeded by its position in the bond). `relief` scales the normal map. Everything
here is tuning and lives here; the client has defaults that mirror these and nothing else.

### 2. The detail is drawn once, at boot, into textures generated from those numbers

Per material with a pattern, the client paints on a canvas at boot — no image files, no
downloads — three textures covering a fixed **2 m × 2 m** of surface, `RepeatWrapping`,
mipmapped, anisotropy at the renderer's maximum:

- **albedo**: the pattern's units in value space with per-unit `variation`, joints at
  `joint_shade`;
- **normal**: derived from a height map in which joints are recessed and tile courses
  step, scaled by `relief`; `MeshStandardMaterial.normalMap` needs no tangents on this
  geometry — three derives them from screen-space derivatives;
- **roughness**: joints rougher than faces, glass smooth inside its frame.

Textures rather than a pattern evaluated per fragment in the shader, for three reasons. A
mortar line is a few millimetres wide: evaluated per fragment it aliases into shimmer at
thirty metres unless filtered by hand, where a texture's mipmaps filter it for free. The
normal map is the same picture; a per-fragment pattern would need its own derivative
machinery for the relief. And headless Chrome's software rasteriser runs the suite: a
texture fetch is the cheapest thing a fragment can do. The pattern is still procedural —
every pixel comes from the Ruby numbers, the same on every machine.

Repetition every two metres is invisible on brick (a bond has no landmarks) and mitigated
on tiles and planks by the per-cell jitter in §4. If it ever shows, the tile grows to 4 m
at four times the memory; the size is a constant in `render/looks.js`, not a rule.

### 3. Texture coordinates are metres along the surface, continuous across cells

A wall is one object that happens to be destructible, and its bond has to run across cells
as if the cells were not there. Each instance therefore carries its cell's offset along its
surface in metres, `cellUV = [col × cell_width, row × cell_height]`, as an
`InstancedBufferAttribute` written beside the instance matrix, and a vertex shader chunk
(`onBeforeCompile` replacing `#include <uv_vertex>`) computes the texture coordinate:

- the instance's scale is the length of the instance matrix's columns — `cell_width`,
  `cell_height`, `thickness` — so the unit cube's local position in `[-0.5, 0.5]` becomes
  metres;
- a face whose object-space normal is ±z (the two wall faces) maps `(x, y) + cellUV`, so
  the bond continues into the neighbouring cell and course lines stay level along the
  whole row;
- a face whose normal is ±x or ±y (the cross-section exposed where a cell is missing) maps
  `(z, y)` or `(x, z)` with no offset, so a hole shows brick ends and a course's thickness
  rather than a stretched face;
- the pattern's v axis runs along the surface's `v`: up a wall, up a roof slope, across a
  deck.

`cellMatrix`'s basis is `(u, v, n)` with scale `(width, height, thickness)`, so object-space
axes and the surface's axes are the same thing; nothing about the matrix changes. Falling
slabs (`chunkMatrix`) span several cells: their `cellUV` is the first cell's, and the slab's
scale carries the rest, so a slab keeps the bond it fell with. Shards and remnants are
plain meshes and take the material's texture with a fixed coordinate; at their size nobody
can tell.

### 4. Palettes: a building's colours are one key, applied per instance

`Game::Palettes` is a frozen table like `Materials`, shipped whole:

```ruby
red_brick:   { brick: "#9a4b32", mortar: "#b7ad9b", roof_tile: "#7a3a2c", door: "#2f4b3e", frame: "#efe9dc" }
brown_brick: { brick: "#7d5236", mortar: "#a99f8f", roof_tile: "#3b3d43", door: "#5a2a1e", frame: "#e8e2d4" }
sand_brick:  { brick: "#c8a878", mortar: "#d8d0c0", roof_tile: "#8d4a35", door: "#33383d", frame: "#f2ede2" }
dark_brick:  { brick: "#4e3a33", mortar: "#8a8278", roof_tile: "#2e3034", door: "#7a2c22", frame: "#d9d2c5" }
church:      { brick: "#6e4a3a", mortar: "#a09684", roof_tile: "#3a3f47", door: "#3a2a22", frame: "#c9c1b3" }
```

Every recipe carries `palette` (a key; `building` recipes default to `brown_brick`, which
is tuned to reproduce today's colours closely enough that the four worlds look like
themselves). The importer picks one per row from the seed, weighted by category and year:
this estate is 1987 brown-and-red brick under anthracite or orange tiles; the church gets
`church`.

The client applies it where damage darkening is already applied: the instance colour.
`tint = palette[role] × jitter × shade`, where `role` is the material's palette role
(`brick` for brick cells, `roof_tile` for tiles, `door` for the new `door` material, the
material's own colour for glass, steel, plaster, concrete), `jitter` is a seeded ±3%
lightness per cell so a wall is not one flat value, and `shade` is the existing damage
factor. Because the albedo is value-space, the multiplication IS the colouring, and one
pool still serves every building whatever its palette. No new draw calls.

### 5. Openings with meaning

All of this is Ruby, in the `row` generator and `Openings`; the `building` recipe keeps its
current door and windows so the four worlds do not move.

- **A `door` material** joins the table: timber's numbers, its own palette role, so a door
  is coloured as a door and a deck as timber. `Building.countMaterials` sizes its pool like
  any other.
- **House fronts**: a one-cell door at ground level with a two-cell window beside it, and
  one-cell windows upstairs at the current rhythm. A three-metre door is a garage, and the
  drive-through argument that made it wide never needed the door: you drive through the
  wall, and the wall is what the game is about.
- **Garages**: the importer marks a box `door: "garage"` when its widest street-facing edge
  — the edge nearest the row's front line, or nearest a road for a box that stands alone —
  is at least 2.5 m and the box is one storey. A garage door is a `door` patch two rows tall
  spanning the face minus half a metre each side, drawn with the planks pattern.
- **Sheds** stay solid (decided in the islands design). **Church**: the nave gets tall
  two-row windows every third column, the tower one small window per storey, chapels a
  window every other column; the nave's door is two cells wide. The rhythm is a table
  `Openings::STYLES` keyed by category, shipped nowhere — it changes surfaces, so it lives
  with the generator and is pinned by the row tests.
- **Window frames** are the glass texture's opaque border (§1), in the palette's `frame`
  colour, so a pane reads as a window without a second material or a second cell.

### 6. Gardens, from the row frame and the roads

The row frame already knows the street side and the roads are already in the spec.

- **Front gardens**: the strip between a row's front line and the nearest road edge (the
  road's centreline offset by half its width), one per dwelling, minus a 1.2 m path from
  the road to each door. Drawn as a grass patch — a quad draped on the terrain exactly as
  a road ribbon is, in `rules.gardens.grass` colour with a second procedural texture
  (`lawn`), merged into the roads' mesh so it costs no draw call.
- **Hedges** along the street edge of each front garden, broken at the paths, are
  **pieces**: a `Surface` of `kind: :hedge`, one row of cells, material `hedge` (a new
  table entry: leaves — health tiny, `structural_weight 0.0`, `toll 0.05`, a green `chunk`,
  a `leaves` pattern), carrying the bay of the dwelling it fronts. A hedge you cannot drive
  through is the one thing this game must not have, and a piece is the only thing here that
  breaks, persists, and reveals to every player alike. It is appended to the `row` recipe's
  order after the boxes and before rubble, which renumbers nothing that already exists in a
  hand-made world (they have no `row` recipes) and regenerates the `geleen` fixtures.
- **Back gardens**: the union footprint's margin behind the row, grass only. The BGT
  `land_covers` table in the sibling database (2,805 green areas, 1,070 yards, 276 hedges
  inside the bounds) is the better source for both and is noted for the pass after this
  one; the road-derived version is what the brief allowed and is enough to make the estate
  read as lived in.
- **Not here**: pavements and kerbs (the next step, as the brief says), trees (4,104 BGT
  trees in the bounds; a prop with a trunk and a crown mesh is its own small design).

### 7. Light, sky and reflections

The sky is `#0e1116` and the fog matches it: the world is lit for night. Brick and tile
detail needs light to read, so this design makes **daylight the default**: a sky gradient
(zenith to horizon, `rules.sky`), the fog to the horizon colour, the sun warmer and higher
with the same shadow setup, and the hemisphere light coloured from the sky. Night stays
one URL parameter away (`?time=night`) with the current values, because the current look
is a deliberate one and the user should be able to compare. Physics does not care, so the
system suite's timing assertions are unaffected; it runs at `quality=low` either way.

Steel renders black because a metalness of 0.85 with nothing to reflect is black. The
scene gets an **environment map** generated at boot from the sky gradient and the ground
colour through `PMREMGenerator`, so metals reflect a horizon and glass gets a highlight.
One texture, computed once.

### 8. Quality tiers

The `low` tier is what the suite is calibrated on, in software. It keeps today's flat
materials: no textures, no normal maps, no environment map, so the timing assertions stand
on exactly the fragment cost they were measured at. Palettes and openings are geometry and
colour and apply at both tiers. `high` gets everything in §2, §3 and §7. A test that wants
to assert on the look (that a texture was generated, its size, that a pool's material
carries a normal map) reads `__arenaLooks()` rather than pixels.

## Data flow

```
Game::Materials (look) + Game::Palettes  ─► spec.materials[*].look, spec.palettes
row recipe { palette, boxes[].door, category } ─► RowGenerator: door/garage/hedge/window surfaces
                                                                 (piece indices, order pinned)
client boot: looks.js paints albedo/normal/roughness per pattern ─► one material per pool
             Building.build writes cellUV per instance, tint = palette × jitter × shade
             roads_view drapes grass patches with the ribbons; sky/env from rules.sky
```

## Edge cases

- **A cell narrower than a brick** (a 0.9 m cell at a 0.21 m brick) shows part of a bond;
  the offset keeps its neighbour continuing it.
- **Rotated rows**: coordinates are along `u`/`v`, never world axes, so the bond is level
  on a row at any bearing.
- **A slab in flight** keeps its texture coordinates and its palette tint; when it lands
  its shards take the material's colour × palette.
- **Damage darkening and palette multiply**; a broken cell is hidden, so the product is
  never seen at zero.
- **A garage candidate that faces the back** (an annex behind the house) is not a garage;
  the test is the street side.
- **A front garden with no road within 25 m** gets none; the strip has to end somewhere.
- **Hedges regenerate `piece_count`** for every `row` recipe: the fixtures are re-imported,
  the dev database re-seeded with `geleen:seed`, and `world_summary_test` proves it.
- **`quality=low`** never allocates a texture, so the suite's memory and timing are as
  before.

## Testing

**Ruby.** `materials_test`: every material with a pattern has complete `look` numbers;
`palettes_test`: every palette names every role and every recipe's palette key exists;
`row_test`: the openings styles per category pin their patches (a one-cell door with a
two-cell window beside it; a garage door two rows tall; the church's rhythm), and hedges
appear after boxes and before rubble with the bay of their dwelling; `generator_test` and
`world_summary_test` stay green (the four worlds unchanged). Importer: `Rows` marks
street-facing wide boxes `garage`, picks a palette per row deterministically from the seed,
and emits front-garden strips clipped by the road edge.

**Browser.** `looks_test.rb` (high quality, one file): `__arenaLooks()` reports a texture
per patterned material with the configured tile size and a normal map on `high`, none on
`low`; a row's brick cells report a `cellUV` that increases by the cell width along the
row; two buildings with different palettes report different tints for the same material;
the `door` pool exists and holds the estate's doors; steel is no longer black (its
material has an environment map). `shots_test` gains the kerb shot of a row and a close-up
of a wall at 3 m, which is how the look is actually judged.

## Migration notes

- `Game::Material` gains `look:` (optional; materials without a pattern draw flat as
  today) and a palette `role:`; `Game::Materials` gains `door` and `hedge`;
  `Game::Palettes` is new; `Game::Spec.default_rules` gains `sky`, `gardens`.
- `Game::Building::Surface` gains `kind: :hedge`; the `row` recipe gains `palette` and
  boxes gain `door: "garage"`; `Openings::STYLES` is new.
- Client: `render/looks.js` (textures, shader chunk, environment), `piece_meshes.js`
  (materials from looks, `cellUV` attribute, composed tint), `building.js` (writes `cellUV`,
  palette tint), `roads_view.js` (grass patches), `scene.js` (sky, daylight, environment),
  `arena_controller.js` (`?time=`).
- `geleen` fixtures re-imported once for hedges, garages, palettes and the new openings.
- `CLAUDE.md`: the look lives in Ruby, textures are generated not shipped, `low` is flat
  on purpose, `?time=night`.

## Out of scope

- Pavements and kerbs. Trees. `land_covers` as the garden source. Interior detail.
  Decals for damage. Anything that adds a draw call per building.
