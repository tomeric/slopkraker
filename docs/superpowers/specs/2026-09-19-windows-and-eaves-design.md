# Windows and eaves: panes that sit in a wall, and a roof that covers one

Date: 2026-09-19
Status: designed. Follows `2026-09-19-roof-fittings-design.md`, which put chimneys on the
ridge, panels on the slope and rainwater goods down the wall. Judged from the same kerb,
this is what the fittings made visible: the roof does not reach the edge of the wall it
sits on, and the glass in that wall is in the way of things.

## Why

Four faults, named from the driver's seat and then measured:

1. **A gutter on a flat deck is a kerb, not a gutter.** Already fixed, in the previous
   phase's commit `75d6c81` -- 507 of geleen's 1,529 gutter boxes were a 120 mm bar along
   one edge of a bounding box. It is listed here only so the set is complete.
2. **The roof does not cover the wall.** A roof plane's lower edge sits at `row.z0` --
   exactly the wall's own plane. A wall is `Walls::THICKNESS` (0.3 m) thick and straddles
   that plane, so its outer face is 150 mm further out than the lowest tile. Every wall top
   on the estate has a 150 mm ledge of open sky above it, and the gutter that was just hung
   "outside and below the eaves line" hangs over that ledge rather than clear of the wall.
   There is an `OVERHANG` constant (0.4 m) and it is spent entirely along the ridge, past
   the gables; down the slope there is none.
3. **A dakkapel is one third window.** Measured: 15 dormer fronts on geleen, 14 of them 3
   columns by 2 rows with a plaster return in the first and last column -- 2 glass cells out
   of 6 -- and the fifteenth 2 by 1 on 1.5 m cells, which already had none. 56 of the 86
   front cells on the island were wall. A dakkapel is a window with a roof over it; that is
   the whole point of cutting one into a roof.

   *(This said 18 when it was written, counted before `3eef78a` mixed the salt through the
   detail-flag hash and re-imported. The shape of the fault was unchanged by that.)*
4. **Walls run through windows**, in two distinct ways and one of them is the common case:
   - **An interior partition lands mid-window on 63 of geleen's 94 end walls.** A partition
     crosses the middle of its dwelling, so it meets the end wall at that wall's middle
     column, and `annex` windows are free to be in it. From the end of a terrace you look
     through the glass at a plaster wall a hand's breadth behind it.
   - **113 openings stand in a corner column** -- 76 on the hand-made `classic` houses, 26
     glass and 11 doors on rows. Two walls meeting at a corner each straddle their own
     plane, so the perpendicular wall eats 150 mm into the end cell. On a 1 m cell that is
     a sixth of the pane buried in brick.
   - Separately, **the roof is still behind every dakkapel's glass**: nothing voids the roof
     cells under a dormer, so the window looks into tiles.

And one thing that is not a fault but is the reason the rest look wrong: **a pane is as
thick as the wall around it**. A `Surface` has one thickness, so a glass cell fills the
wall's full 300 mm and its face is flush with the brick. Real glass sits in a reveal.

## Constraints carried over

- **Every tuning number lives in Ruby.** Both new numbers here -- the eaves overhang and
  each material's drawn depth -- are Ruby constants shipped in the spec.
- **Piece indices are the contract.** Nothing in this phase moves an index: the overhang is
  drawing, the reveal is drawing, and the opening rules change patches only. **No
  re-import, and no `piece_count` moves.** Patches are derived from the seed at generation
  time and are not stored in the fixtures, so a change to where a window goes reaches
  geleen without the importer running.
- **Draw calls track materials.** The overhang is instances in the roof material's existing
  pool, through the attachment store the gable caps introduced.
- The four hand-made worlds move for the first time, and only in section 4 below. That is a
  deliberate, argued exception; see there.

## Decisions

### 1. The eaves overhang is drawing, like the gable caps

A roof plane grows `Roof::EAVES_OVERHANG` (0.4 m) down its own slope, past the wall, as one
instanced box per column of its bottom row -- same material, same thickness, same tint,
keyed to that bottom-row cell and hidden and restored with it. It goes in the attachment
store beside the caps, the gutters and the downpipes, and it has no collider, exactly as
they have none.

**Drawing rather than grid, and the reason is the same one the caps were built on.** Making
the plane genuinely longer changes its `rows`, which changes every piece index after it,
which means a re-import of geleen and a new `piece_count` on every fixture -- to move the
bottom edge of a roof 40 cm. A cap taught this codebase that the fix for "the wall stops
short of where the eye expects it" is an instance keyed to the cell that does stop there.

**The gutter moves out with it.** `fittings.js` hangs a gutter on the eaves line; the eaves
line is now the overhang's outer edge, not the wall's plane. The two must be computed from
one number, so `gutters` reads the same constant the overhang does.

### 2. A pane is thinner than the wall that holds it: `Material#depth`

`Game::Materials` gains **`depth`** -- the fraction of its surface's thickness a cell of
this material occupies, centred on the plane, default `1.0`. `glass` is `0.35` and `door`
is `0.7`. It ships in the material table and the client scales the cell's instance matrix
along the surface normal by it.

**Every number the server reasons about keeps using the surface's own thickness.**
`health_for`, mass and the rubble `mix` are the wall's, because what holds a wall up is the
wall and not the pane in it.

**The collider is thinner too.** This was written the other way first, on the grounds that
two thicknesses in the physics were not worth it -- but there are not two. There is one
matrix per cell, and it feeds the instance and the cuboid alike; keeping the collider at
full thickness means composing a second matrix for it and holding the pair in step forever,
which is more machinery than the thing it protects. A 105 mm pane recessed 97.5 mm behind
the brick face is also the better answer: a blade scraping a wall meets the brick before it
meets the glass, which is what a wall does.

**`solar` takes NO depth**, and the reason is worth keeping because the first draft of this
document got it wrong. A panel is a PATCH: it replaces the tiles it covers rather than lying
on them. A depth is centred on the plane, so it can only sink a cell and never stand it
proud -- at `0.25` a panel came out as a 50 mm sheet 75 mm below the tiles, a dark rectangle
in a well. A panel that genuinely stood on a roof would be the DRAWING mechanism the gutters
and the gable caps use, which is section 1's machinery and a different change.

**A falling slab takes its material's depth as well.** A slab is tiled from cells of one
material, so `chunkMatrix` can scale by the same factor -- and must, or a pane that stood as
105 mm falls as 300 mm and visibly fattens in the frame the house is condemned.

### 3. A dakkapel is a window

Drop the plaster returns from `RowGenerator.dormer`: the front is glass in every cell, at
every width. The comment that justifies the returns ("under three columns there is no
middle left to be a window") is inverted by this -- there is no middle because the whole
face is the window.

And **void the roof cells under the dormer**, so the glass looks into the roof space rather
than at tiles. The dormer's footprint on the plane is known where it is built; the void
patch goes on the plane, costs no index, and is the same mechanism a doorway is.

If the phase before this one has already voided them -- its `dormer_plan` was mid-flight
when this was written -- this reduces to the returns alone. Check before implementing.

### 4. No opening in a column another wall lands in

`Openings#for_wall` gains **`reserved:`**, a list of columns the wall's owner knows are
crossed. Every window run, front window, garage door and glazing patch is rejected or moved
off a reserved column; a door is never reserved away, because a door in a corner is a
detail and a door that vanishes is a house you cannot enter.

The caller computes the list, because the caller is the only thing that knows the building:

- **Always the first and last column**, for every wall of every recipe. Two walls meeting at
  a corner always overlap by half a thickness; there is no building where this is not true.
- **The column an interior partition lands in**, for the walls that partition meets. A
  partition sits at mid-depth, so it is the middle column of each end wall.

**This moves the hand-made worlds, and that is the argued exception.** `classic` has been
byte-identical to its pre-styles self by rule since the styles arrived, and the rule is
worth breaking exactly here: the defect is in `classic` too, four panes of the targets
house are buried in their own corners, and a rule that keeps a known fault frozen is a rule
that has stopped paying. No index moves -- only which cells are glass -- so the cost is
`building_test`'s material census, which must be re-measured rather than guessed.

### 5. What is not being done

The wall itself is not shortened. Butting walls at a corner instead of overlapping them
would change each wall's length, which changes `Walls.cells`, which moves piece indices for
every building in every world. The overlap is how bricks actually meet; the fault was only
ever the glass in it.

## Testing

**Ruby.** `materials_test`: every material carries a `depth`, it is in `(0, 1]`, and glass's
is less than brick's. `openings_test`: a reserved column holds no glass in any style, a run
that would have covered one is moved or dropped, and a door is placed in one regardless.
`row_test`: a dormer front is glass in every cell at 2, 3 and 5 columns; the roof plane
under it carries the void patch; the pinned offsets and the 840-piece count are unchanged.
`generator_test`: the worked example's offsets and count are unchanged, and its census is
re-measured.

**Browser.** `fittings_test`: a gutter's outer face is clear of the wall below it, which is
the assertion the overhang exists for. `eaves_test` (new, `targets` at low): every column of
a pitched plane's bottom row carries an overhang instance; breaking that cell hides it;
`__arenaDraws()` is unchanged, because it is the roof's own pool. `building_test`: the
re-measured census. `shots_test`: re-shoot 20, 22, 25 and 27, and add one close shot of an
eaves from below, which is the only way to see whether a roof covers a wall.

## Out of scope

Fascia and soffit boards, window frames as geometry, sills, lintels over ordinary windows,
flashing where a box roof meets a wall, dormer gutters. Shortening walls at corners, per
section 5.
