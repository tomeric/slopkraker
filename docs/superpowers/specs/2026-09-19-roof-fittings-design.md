# Roof and facade fittings: chimneys, solar panels, gutters and downpipes

Date: 2026-09-19
Status: designed. Follows `2026-09-18-house-details-design.md`, which gave a dwelling its
windows, its garage, its dakkapel and a gable that meets the roof. This is the next pass
over the same estate, judged from the same kerb: what is on the roof and down the wall.

## Why

The roofs are bare. A 1987 estate has a chimney at most party walls, panels on a good share
of the sun-facing slopes by now, a zinc gutter along every eaves and a downpipe at every
corner. They are small things, but they are the ones the eye counts: a roof with a dakkapel
and no chimney reads as a model of a roof.

## Constraints carried over

- **Every tuning number lives in Ruby**, including every size here.
- **Piece indices are the contract.** A patch never moves an index. A chimney is surfaces,
  so it goes in a fixed place in the order (step 5c) and only when a dwelling is flagged;
  an unflagged row keeps its numbering byte for byte. `geleen` is re-imported once.
- **Draw calls track materials.** Gutters and downpipes are instances in the pool `steel`
  already has. Nothing here adds a mesh per building.
- **The four hand-made worlds must not move.** Everything is on the `row` recipe.

## Decisions

### 1. Three kinds of thing, three mechanisms, chosen by what breaking one should do

- **A solar array is a PATCH** — cells of a new `solar` material on a roof plane. It breaks
  with the roof cell it replaces, costs no index, renumbers nothing, and is already counted,
  coloured, shattered and swept by everything that handles a patch today.
- **A chimney is PIECES** — four thin walls standing on the ridge. You should be able to
  take it off with a rocket and watch it come down, and only a piece does that.
- **A gutter and a downpipe are DRAWING** — instanced boxes keyed to the cell they hang on,
  hidden and restored with it, exactly as the gable caps are. A gutter is 120 mm of folded
  zinc; giving it its own indices would add a surface per roof plane and a surface per wall
  for something a player can only ever see. It goes when the thing it is nailed to goes,
  which is the honest behaviour and the cheap one.

### 2. Solar panels: the `solar` material and the `panels` pattern

`Game::Materials` gains `solar`: glass's fragility with a little more mass, `hardness: 0`,
`structural_weight: 0.0`, its own `chunk`, `role: nil` — a panel is the same colour on every
house, so it takes no palette — and a `look` with the new `panels` pattern: a near-black
field, a fine grid of cells, and a lighter frame line at each module's edge. `Material::
PATTERNS` and `looks.js`'s `PATTERNS` gain it together, as the materials test demands.

Placement is `RowGenerator`'s, not `Openings`' — openings own walls, and this is a roof.
When a dwelling is flagged, its sun-facing roof plane gets one rectangle of `solar` cells:
inset one cell from every edge, at most `SOLAR_COLS` (4) wide and `SOLAR_ROWS` (2) tall,
centred on the plane, and none at all if the plane has fewer than three columns or three
rows after the inset.

**The sun-facing plane is decided from the row's yaw and nothing else.** `Frame#to_game`
negates RD north, so **game +z is south**. In the row's own frame the back plane's outward
normal is +z and the front plane's is −z, so the back plane faces south exactly when
`cos(yaw) > 0`. One rule, four pinned cases in the tests, no new recipe field.

### 3. Chimneys: four walls in step 5c

A chimney is `CHIMNEY_SIDE` (0.9 m) square in plan and stands `CHIMNEY_RISE` (1.2 m) above
the ridge, on the ridge line, at the dwelling's party-line end — which is where a terrace's
flues actually run, and why the chimneys of a real row come in pairs. Four `brick` walls,
one column and however many rows the cell size gives, `storey: row.storeys`, the dwelling's
`bay`, generated immediately after that dwelling's dormer: **step 5c of the order**.

None on a flat roof, none when the dwelling is narrower than `2 × CHIMNEY_SIDE`, and the
stack stands on the ridge whatever the roof's pitch, so its foot is buried in the roof by
design — the four walls start at the eaves height and run to the ridge plus the rise, and
the part inside the roof is never seen.

### 4. Rainwater goods: `render/fittings.js`, drawn against a cell

- **A gutter** runs along the eaves edge of every roof plane: one box per column of the
  plane's bottom row, `GUTTER_SIDE` (0.12 m) square in section, hung just outside and below
  the eaves line, keyed to that bottom-row cell.
- **A downpipe** runs down the outer end of each dwelling's front and back wall: one box per
  storey, the same section, keyed to the end column's cell on that storey.

Both are instances in `steel`'s existing pool — zinc is what the dormer's top already uses —
and both go through the attachment store the gable caps introduced, which this change
renames from `caps` to `attachments` because it is no longer only caps. No colliders, as
the caps have none.

### 5. The importer

`solar` and `chimney` join `garage`, `glazing` and `dormer` as per-dwelling flags from
`Rows.detail?` with their own salts, on `lived_in` categories only, gated on a gable roof
(both) and on the dwelling's width (the chimney). Shares: **solar 30 %**, **chimney 55 %**.
Gutters and downpipes need no flag — every house has them — so they cost no fixture change.

## Testing

**Ruby.** `materials_test`: `solar` is complete, fragile, holds nothing up and ships its
look. `row_test`: a flagged dwelling's sun-facing plane carries one `solar` rectangle of the
pinned size and position and the other plane carries none; the four yaw quadrants pick the
plane the rule says; a chimney is four surfaces with the pinned offsets in step 5c and an
unflagged row is byte-identical (29 surfaces, 840 pieces). `rows_test`: both flags appear on
some dwellings and never outside their gates. `world_summary_test` over the re-import.

**Browser.** `fittings_test.rb` (new, `targets` at low): every eaves column of the house has
a gutter and every storey of its end columns a downpipe; breaking the cell one hangs on
hides it and restoring brings it back; the whole lot is one pool (`__arenaFittings()` reports
distinct pools) and `__arenaDraws()` stays under its ceiling. `shots_test` gains a shot from
above the kerb where a roof is actually visible.

## Out of scope

Aerials, satellite dishes, ventilation stacks, dormer gutters, chimney pots, snow guards.
Pavements, kerbs and trees, as before.
