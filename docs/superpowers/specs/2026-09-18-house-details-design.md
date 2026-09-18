# House details: windows with width, garages in the front, glass at the back, gables that meet the roof, dakkapellen

Date: 2026-09-18
Status: designed. Follows `2026-09-18-how-buildings-look-design.md`, which gave every wall a
material and every building a palette. This is the next pass over the same estate, judged
from the same kerb: the things a Dutch terrace has that ours did not.

## Why

From the kerb the estate now reads as brick terraces, and five things still say "generated":

- Every window upstairs is one cell wide, every front window two. Real fronts mix them.
- The gable ends climb in whole-cell stairs. The overhang hides the last step at a row's
  end; everywhere else the wall stops short of the roof in teeth.
- No house has a dakkapel. Half of a 1987 estate does.
- The garage doors the importer found are three in forty-eight buildings, because it looks
  for a separate garage box and this estate builds the garage INTO the house, under the
  first floor, with its door in the front wall.
- The backs are brick with small windows. Many have floor-to-ceiling glass on the ground
  floor.

## Constraints carried over

- **Every tuning number lives in Ruby.** Widths, heights, proportions and materials ship in
  the recipe or the spec; the client draws what it is told.
- **Piece indices are the contract.** Openings change PATCHES (which cells are glass, door
  or void) and never grids. Dakkapellen are new SURFACES with real indices, generated in a
  fixed place in the order. The four hand-made worlds must not move: everything here is on
  the `row` recipe and its `:house` style. `geleen` is regenerated once by `geleen:import`
  and re-seeded with `geleen:seed`.
- **Draw calls track materials.** The gable caps are extra instances in pools that already
  exist plus one new wedge-shaped pool per material that has a gable, never a mesh per
  building.
- **What is decided per dwelling is decided by the importer from the seed**, written into
  the recipe, and never guessed by the generator. The generator turns flags into geometry.

## Decisions

### 1. Windows come in runs of one or two cells

`Openings::STYLES[:house]` (and `:annex`, the ends of a row) replace the fixed
every-other-column rhythm with **runs**: walking the face from a seeded start, each window
is one or two cells wide, drawn from the seed per run, separated by exactly one pier, and
never reaching the last column. `:classic` keeps its old rhythm byte for byte. A two-cell
window is one patch two columns wide, so it reads as one window with a mullion.

### 2. A dwelling may carry an integrated garage

`Dwelling` gains `garage: true|false`. On the ground floor of the front, a dwelling with a
garage gets: the front door one cell wide at one end as now, one pier, then a **garage
door three cells wide and two rows tall in the `door` material**, and no front window.
The face needs six columns; narrower fronts get no garage whatever the flag says (the
importer never sets it on them). The importer sets it on about a third of dwellings at
least 5.5 m wide, by seed, only in rows that have no separate garage box, and never on
the church island's apartments.

### 3. A dwelling may have glass from floor to ceiling at the back

`Dwelling` gains `glazing: true|false`. On the ground floor of the BACK wall a glazed
dwelling gets one glass patch **three cells wide (two when the face has fewer than five
columns) spanning every row**, its position drawn from the seed, and no other window on
that storey of that face. Glass holds nothing up, so a glazed back contributes less
support; the collapse rule compares against the building's own starting state, so the
house stands until it is hit. The importer sets it on about a third of dwellings, by seed.

### 4. Gable ends meet the roof

The stair stays as pieces — those are the indices — and the client fills the tooth above
every column's topmost standing cell with two extra instances in the gable's own material
and tint: a **box** up to the lower of the roof line's two heights across that column, and
a **wedge** (a unit right-triangular prism, a new shape pool named `<material>#wedge`) from
there to the higher one, turned toward the apex. The apex column gets two half-width
wedges. The roof line is the one `Roof.clip` judges by: `1 − |2·across − 1|` of the
gable's height, evaluated at the column's two edges. Both instances are drawn and hidden
with the cell they sit on: broken, they go; restored, they return; a falling slab that
carries the cell throws its shards as it did and leaves nothing hanging. `Building.
countMaterials` counts them exactly as the builder places them, because an `InstancedMesh`
cannot grow. Colliders are untouched — the tooth was never something a car could hit.

### 5. Dakkapellen

`Dwelling` gains `dormer: true|false`. A dwelling with a dormer gets four more surfaces
generated **immediately after its roof section**, on the FRONT roof plane:

- a **front** face, `glass` with a `plaster` return at each end column, `DORMER_WIDTH`
  (3 m, clamped to the dwelling's width minus 2 m) wide and `DORMER_HEIGHT` (1.5 m) tall,
  standing vertical at `DORMER_SETBACK` (1.0 m) in from the eaves line;
- two **cheeks**, `plaster`, from the front face back to where the flat top meets the roof
  again — the rectangle's lower rear corner lies inside the roof and is never seen;
- a **top**, a flat `steel` deck (zinc), from the front face to that meeting line.

The front face's foot is on the roof plane: at setback `d` its base is `eaves + rise·d/run`;
the top is `DORMER_HEIGHT` above; the roof reaches that height at `d + height·run/rise`.
A dormer that would meet the roof past the ridge is not generated (the importer only
flags dwellings whose roof has room: rise ≥ 2.5 m and `d + height·run/rise ≤ run − 0.5`).
The surfaces carry `storey: row.storeys` and the dwelling's `bay`, so they fall with it.
The importer flags about 45 % of dwellings at least 4.5 m wide, by seed.

**The order gains a step 5b.** Dwellings' fronts and backs (1), ends (2), party walls (3),
interiors (4), then per dwelling its roof section (5) followed by its dormer (5b), then
boxes (6), hedges (7), rubble last. Rows without dormers keep their numbering; rows with
them renumber everything after the roof, which the re-import absorbs. `row_test` pins the
offsets of a pair with one dormer.

### 6. Importer

`Rows#build` decides `garage`, `glazing` and `dormer` per dwelling from `seed` and the
dwelling's index with a small deterministic hash, subject to the geometric conditions in
§2, §3 and §5, and writes them into `recipe["dwellings"][i]`. Nothing else changes; the
palette, gardens and garage boxes stay as they are.

## Testing

**Ruby.** `row_test`: window runs are one or two wide with one pier between and never touch
the last column, and `:classic` is unchanged (the `building` worked example); a garage
dwelling's front is door, pier, three-cell `door` patch, nothing else; a glazed dwelling's
back has one glass patch spanning every row and no other ground-floor window; a dormer's
four surfaces come right after the dwelling's roof section with the pinned offsets and
sizes, and a dwelling whose roof has no room gets none; the pair with no flags is byte for
byte what it was (29 surfaces, 840 pieces). `rows_test`: each flag appears on some but not
all estate dwellings, never on a front narrower than six cells (garage) and never where the
roof has no room (dormer). `world_summary_test` and `fixtures_test` over the re-import.

**Browser.** `gables_test.rb` (new, `targets` at low — the hand-made house has two gables):
`__arenaGableCaps(id)` reports caps for every gable column that has a tooth, breaking a
column's top cell hides its caps and restoring shows them, and `__arenaDraws()` grows by at
most one pool per gable material. `shots_test`'s kerb and three-metre shots are the
judgement.

## Out of scope

Chimneys, rainwater pipes, side doors, balconies; dormers on the back; anything on the
`building` recipe; pavements and trees as before.
