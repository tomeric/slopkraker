# Windows and eaves Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a roof cover the wall it sits on, make a pane sit inside the wall that holds
it, make a dakkapel a window, and stop other walls standing in front of the glass.

**Architecture:** Four independent changes, three of them drawing-only. The eaves overhang
and the window reveal are instanced geometry and an instance scale; the dakkapel and the
opening rules are patches. **Nothing moves a piece index, so there is NO re-import and no
`piece_count` changes anywhere.**

**Tech Stack:** Rails 8.1 / plain-Ruby `app/models/game/**`, three.js 0.170 vendored,
Rapier wasm, Minitest + Capybara headless Chrome.

**Spec:** `docs/superpowers/specs/2026-09-19-windows-and-eaves-design.md`

## Global Constraints

- Work on `main`. No worktree. Commit as soon as each task is green; keep turns short.
- **Every tuning number lives in Ruby** and ships in the spec. No constant in JavaScript.
- **Piece index space is never culled, only geometry is.** No task here may change any
  surface's `cols`, `rows`, or the order surfaces are generated in.
- **No re-import.** `bin/rails geleen:import` must not run. Patches are derived from the
  seed at generation time, so a change to where a window goes reaches geleen for free.
- **Never run `db:seed` or `db:reset`.** Use `bin/rails geleen:seed` if a world row needs
  refreshing. A reseed replaces hand-made world rows and orphans their matches.
- The dev server on port 3100 stays up. Never kill it.
- Do not run the full system suite between steps. Run the one file that covers the change.
  A system run takes a machine-wide lock; if it blocks, wait, and re-run once on a stall.
- Attribute 3DBAG (CC BY 4.0, TU Delft) and AHN (PDOK) wherever imported data lands.
- End every commit message with exactly:
  `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`
- Your scratchpad is SHARED with other agents in this session. Prefix any temporary file
  with your own task number or it will be clobbered mid-run.

---

### Task 1: A pane is thinner than the wall that holds it

**Files:**
- Modify: `app/models/game/material.rb` (add the attribute and ship it)
- Modify: `app/models/game/materials.rb` (`glass`, `door`, `solar` get a depth)
- Modify: `app/javascript/game/world/surface.js` (`cellMatrix` takes a depth)
- Modify: `app/javascript/game/world/building.js` (pass the material's depth)
- Test: `test/models/game/materials_test.rb`, `test/system/looks_test.rb`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `Material#depth` (Float in `(0, 1]`, default `1.0`), shipped in the material
  table as `depth` only when it is not 1.0; `cellMatrix(surface, row, col, target, origin,
  depth = 1)`.

- [ ] **Step 1: Write the failing Ruby test**

In `test/models/game/materials_test.rb`:

```ruby
test "a pane is drawn thinner than the wall that holds it" do
  assert_equal 1.0, Game::Materials.fetch(:brick).depth
  assert_operator Game::Materials.fetch(:glass).depth, :<, Game::Materials.fetch(:brick).depth
  Game::Materials::TABLE.each_value do |material|
    assert_operator material.depth, :>, 0.0, "#{material.name} has no depth"
    assert_operator material.depth, :<=, 1.0, "#{material.name} is thicker than its wall"
  end
end

test "depth ships only when it is not the wall's own" do
  assert_not Game::Materials.fetch(:brick).to_spec.key?(:depth)
  assert_in_delta 0.35, Game::Materials.fetch(:glass).to_spec[:depth], 1e-9
end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bin/rails test test/models/game/materials_test.rb`
Expected: FAIL, `NoMethodError: undefined method 'depth'`.

- [ ] **Step 3: Add the attribute**

In `app/models/game/material.rb`, add `depth` to the initializer with a default of `1.0`,
expose it with `attr_reader`, and in `to_spec` emit it only when it differs:

```ruby
# How thick a cell of this material is DRAWN, as a fraction of its surface's thickness,
# centred on the plane. Glass in a 300 mm wall is not 300 mm of glass; a pane sits in a
# reveal. Drawing only -- health, mass and everything the server reasons about keep using
# the surface's own thickness, because what holds a wall up is the wall, not the pane.
spec[:depth] = depth unless depth == 1.0
```

- [ ] **Step 4: Give glass, door and solar their depths**

In `app/models/game/materials.rb`: `glass` gets `depth: 0.35`, `door` `depth: 0.7`,
`solar` `depth: 0.25`. Nothing else changes.

- [ ] **Step 5: Run the Ruby tests**

Run: `bin/rails test test/models/game/materials_test.rb test/models/game/spec_test.rb`
Expected: PASS.

- [ ] **Step 6: Take the depth on the client**

In `app/javascript/game/world/surface.js`, give `cellMatrix` a sixth parameter and use it:

```js
export function cellMatrix(surface, row, col, target, origin, depth = 1) {
  ...
  target.scale(scale.set(width, height, surface.t * depth))
```

Explain in the comment above the scale that the depth is the material's, that it is centred
because cells already straddle the plane, and that a collider built from this matrix is
thinner too, which is correct and harmless: a recessed pane is met a few centimetres later
than the brick around it.

In `app/javascript/game/world/building.js`, at the one call that builds a cell's matrix,
pass `this.materials[name]?.depth ?? 1`. Do NOT change `heapMatrix` or the slab path.

- [ ] **Step 7: Check the JS parses**

Run: `~/.local/share/mise/shims/node --check app/javascript/game/world/surface.js && ~/.local/share/mise/shims/node --check app/javascript/game/world/building.js`
Expected: no output.

- [ ] **Step 8: Run the browser test that renders a window**

Run: `bin/rails test test/system/looks_test.rb`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add -A && git commit -m "$(cat <<'EOF'
Set a pane into its wall instead of filling it

A Surface has one thickness, so a glass cell filled the wall's full 300 mm and sat
flush with the brick. Materials gain a drawn depth -- a fraction of the surface's
thickness, centred -- and glass, doors and panels take less than all of it.

Drawing only. Health and mass still come from the surface, because what holds a wall
up is the wall and not the pane in it.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: The roof covers the wall

**Files:**
- Modify: `app/models/game/building/roof.rb` (the constant)
- Modify: `app/javascript/game/world/fittings.js` (the overhang boxes, and the gutter moves out)
- Modify: `app/javascript/game/world/building.js` (`countMaterials` counts them)
- Test: `test/system/fittings_test.rb`, `test/models/game/spec_test.rb`

**Interfaces:**
- Consumes: the attachment store and `fittingsFor(surface)` from the previous phase.
- Produces: `eaves(surface)` in `fittings.js`, returning boxes in the same shape
  `gutters`/`downpipes` return (`{u0, v0, n0, su, sv, sn, anchorRow, anchorCol, pool}`).

- [ ] **Step 1: Read what is already there**

Read `app/javascript/game/world/fittings.js` end to end, and the `buildFittings` and
`countMaterials` blocks in `building.js`. The overhang follows the exact same shape as a
gutter: boxes keyed to a cell, counted in `countMaterials`, placed in `buildFittings`,
hidden with their cell. Match it rather than inventing a second path.

- [ ] **Step 2: Write the failing browser test**

In `test/system/fittings_test.rb`:

```ruby
# A roof plane's lower edge sits on the wall's own plane, and a wall straddles that plane
# -- so without an overhang the outer 150 mm of every wall top has open sky above it, and
# the gutter hangs over the gap rather than clear of the wall. The assertion is that the
# eaves reach PAST the wall, which is the whole of what an overhang is for.
test "the roof reaches past the wall it sits on" do
  visit_world("targets", match: "eaves-reach")
  wait_for(message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }

  reach = page.evaluate_script("window.__arenaEavesReach()")
  assert_operator reach["planes"], :>, 0, "the house has no pitched roof plane"
  assert_equal 0, reach["short"], "every pitched plane should reach past the wall below it"
  assert_operator reach["overhang"], :>, 0.3
end
```

- [ ] **Step 3: Run it and watch it fail**

Run: `bin/rails test test/system/fittings_test.rb`
Expected: FAIL, `__arenaEavesReach is not a function`.

- [ ] **Step 4: Name the number in Ruby**

In `app/models/game/building/roof.rb`, beside `OVERHANG`, add:

```ruby
# How far the tiles reach DOWN the slope, past the wall. OVERHANG above is spent along
# the ridge, past the gables; this is the other direction and they are not the same
# number just because they are the same size today. A wall straddles its own plane and a
# roof plane starts on it, so without this the outer half of every wall top is open sky.
EAVES_OVERHANG = 0.4
```

Ship it in the rules the client already receives, beside the other roof numbers, so the
client holds no constant of its own. Find where `Roof::OVERHANG` or the collapse rules are
serialised in `app/models/game/spec.rb` and add it there; pin it in `spec_test.rb`.

- [ ] **Step 5: Build the overhang**

In `fittings.js`, add `eaves(surface)`: for a **pitched roof plane only** (`surface.kind ===
"roof"` and `|v.y|` above the same epsilon the flat-deck gutter guard uses), one box per
column of row 0, extending `EAVES_OVERHANG` from the plane's bottom edge along `-v`, with
`sn` equal to the surface's own thickness and the pool the surface's own material. Add it to
`fittingsFor` so it flows through counting, placing, hiding and restoring untouched.

Then move the gutter: it hangs at the outer edge of the overhang, not at the plane's bottom
edge. Compute both from the one constant and say so in a comment.

- [ ] **Step 6: Expose the probe**

Add `__arenaEavesReach()` to the engine's debug hooks beside `__arenaFittings`: for every
pitched roof plane in the world, compare the outermost point of its eaves against the
outermost face of the wall below it, and return `{planes, short, overhang}` where `short`
counts planes whose eaves do not clear the wall.

- [ ] **Step 7: Run the test**

Run: `bin/rails test test/system/fittings_test.rb`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "$(cat <<'EOF'
Reach the tiles past the wall, and hang the gutter off them

A roof plane started on the wall's own plane, and a wall straddles that plane -- so the
outer 150 mm of every wall top had open sky above it and the new gutter hung over the
gap. The tiles now reach EAVES_OVERHANG down the slope past the wall, as instances
keyed to the bottom-row cell, and the gutter hangs off their outer edge.

Drawing, like the gable caps: a longer plane would be more rows, and more rows is every
piece index after it.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: A dakkapel is a window

**Files:**
- Modify: `app/models/game/building/row_generator.rb` (`dormer`, and the roof void)
- Test: `test/models/game/building/row_test.rb`

**Interfaces:**
- Consumes: `dormer_plan(row, d)` if the previous phase left one; check first.
- Produces: nothing other tasks read.

- [ ] **Step 1: Check what the previous phase already did**

Run this and read the answer before writing anything:

```bash
bin/rails runner 'v=0; World.find_each { |w| w.world_objects.where(kind: "building").each { |o| o.surface_set.surfaces.each { |s| v += s.patches.count { |p| p.material == :void } if s.kind == :roof && s.material.name == :roof_tile } } }; puts "voids on tiled roof planes: #{v}"'
```

It was 52 when this plan was written, and none of them were under a dormer. If it is still
52, both halves of this task are needed. If it has grown by about 18 dormers' worth, the
roof void is already done and only the returns remain.

- [ ] **Step 2: Write the failing test**

In `test/models/game/building/row_test.rb`:

```ruby
test "a dakkapel is a window, not a wall with a window in it" do
  row = row_with_dormer   # the fixture this file already uses for dormer cases
  front = Game::Building::RowGenerator.build(row).surfaces.find { |s| s.material.name == :glass && s.kind == :wall }

  assert front, "the dormer has no front"
  assert_empty front.patches.select { |p| p.material == :plaster },
    "a dakkapel front is glass in every cell"
end

test "the roof behind a dakkapel is open" do
  row = row_with_dormer
  plane = Game::Building::RowGenerator.build(row).surfaces.find { |s| s.kind == :roof && s.material.name == :roof_tile }

  assert plane.patches.any? { |p| p.material == :void }, "the dormer looks straight at the tiles"
end
```

- [ ] **Step 3: Run it and watch it fail**

Run: `bin/rails test test/models/game/building/row_test.rb`
Expected: FAIL on the plaster returns.

- [ ] **Step 4: Drop the returns**

In `RowGenerator.dormer`, delete the `returns` local and pass `patches: []` to the front.
Replace the comment with the reason:

```ruby
# A dakkapel is a WINDOW with a roof over it. It had a plaster return in the first and
# last column, which on every dormer geleen has -- three columns by two rows -- left two
# glass cells out of six. Cutting a box into a roof to put a third of a window in it is
# not worth the roof it costs.
```

- [ ] **Step 5: Open the roof behind it**

In `roof_section`, on the plane the dormer stands on, add a `void` patch over the dormer's
columns and rows. The dormer's footprint on the plane is what `dormer_plan` already
computes for the panels; reuse it rather than working it out twice. If `dormer_plan` does
not exist, add it with the same shape and use it for both.

**Do not change `cols` or `rows`.** A void patch is an index that holds nothing, exactly as
a doorway is.

- [ ] **Step 6: Run the tests**

Run: `bin/rails test test/models/game/building/row_test.rb test/models/game/building/generator_test.rb`
Expected: PASS, including the pinned offsets and piece count, which must NOT move.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "$(cat <<'EOF'
Make a dakkapel a window, and open the roof behind it

Every dormer front on geleen was three columns by two rows with a plaster return at each
end: two glass cells out of six. A dakkapel is a window with a roof over it, so the front
is glass in every cell -- and the roof cells behind it are void, because a window that
looks at tiles is a box glued to a slope.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: No opening in a column another wall lands in

**Files:**
- Modify: `app/models/game/building/openings.rb` (`reserved:`)
- Modify: `app/models/game/building/walls.rb` and
  `app/models/game/building/row_generator.rb` (the callers work the list out)
- Test: `test/models/game/building/openings_test.rb`, `row_test.rb`, `generator_test.rb`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `Openings#for_wall(edge:, storey:, cols:, rows:, reserved: [])`.

- [ ] **Step 1: Write the failing test**

In `test/models/game/building/openings_test.rb`:

```ruby
test "no window stands in a column another wall lands in" do
  openings = Game::Building::Openings.new(seed: 3, style: :annex)
  reserved = [ 0, 4, 8 ]
  patches = openings.for_wall(edge: 1, storey: 0, cols: 9, rows: 3, reserved: reserved)

  glass = patches.select { |p| p.material == :glass }
  assert glass.any?, "reserving three columns should not empty the wall"
  glass.each do |p|
    (p.col0..p.col1).each { |c| assert_not_includes reserved, c, "a pane stands in column #{c}" }
  end
end

test "a door is placed whatever lands on it" do
  openings = Game::Building::Openings.new(seed: 2, style: :house)
  patches = openings.for_wall(edge: 0, storey: 0, cols: 6, rows: 3, reserved: (0...6).to_a)

  assert patches.any? { |p| p.material == :door }, "a house you cannot enter"
end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bin/rails test test/models/game/building/openings_test.rb`
Expected: FAIL, unknown keyword `reserved`.

- [ ] **Step 3: Take the list**

Give `for_wall` a `reserved: []` keyword. Reject any window run, front window, garage door
or glazing patch that covers a reserved column; where a run can be shortened to clear one
rather than dropped, shorten it. Leave the door and its lintel alone. Document why:

```ruby
# Columns another wall lands in. Two walls meeting at a corner each straddle their own
# plane, so the perpendicular one eats half a thickness -- 150 mm -- into the end cell;
# an interior partition does the same in the middle of the wall it meets. Glass in one of
# those columns is a pane with a wall through it, which was 63 of geleen's 94 end walls.
# The caller works the list out, because the caller is the only thing that knows the
# building. A DOOR is never reserved away: a door in a corner is a detail, a door that
# vanishes is a house you cannot enter.
```

- [ ] **Step 4: Work the list out at every call site**

Every caller passes at least `[0, cols - 1]`. In addition, `RowGenerator` passes the column
an interior partition lands in for the two end walls: a partition sits at mid-depth, so it
is `((depth / 2.0) / (depth / cols)).floor`, clamped into range. Do not reach into
`Interior` for it; compute it beside the partition so the two read as one decision, and
comment that they must move together.

- [ ] **Step 5: Run the Ruby tests**

Run: `bin/rails test test/models/game/`
Expected: PASS except `generator_test`'s and `row_test`'s pinned material censuses, which
have legitimately changed. Re-measure them; **do not change any offset or piece count.**
If an offset or a count moves, stop -- something has changed a grid and that is a bug.

- [ ] **Step 6: Re-measure the browser census**

`test/system/building_test.rb` pins the targets house's material census, which changes
because `classic` moves for the first time. Run it, read the actual counts out of the
failure, and update the expectation with a comment saying the four corner panes went.

Run: `bin/rails test test/system/building_test.rb`
Expected: PASS after the census is updated.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "$(cat <<'EOF'
Keep the glass out of the columns other walls land in

An interior partition crosses the middle of its dwelling and meets the end wall at that
wall's middle column, which put a plaster wall a hand's breadth behind the glass on 63 of
geleen's 94 end walls. Two walls meeting at a corner overlap by half a thickness, which
buried 113 more openings in their own corners.

Openings now take the columns their caller knows are crossed and keep windows out of
them. A door is never moved: a door in a corner is a detail, a door that vanishes is a
house you cannot enter.

classic moves for the first time, deliberately. The fault was in it too, and a rule that
freezes a known fault has stopped paying.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Say what changed, and photograph it

**Files:**
- Modify: `CLAUDE.md`
- Modify: `test/system/shots_test.rb`

- [ ] **Step 1: Re-shoot the kerb**

Add one close shot of an eaves from below -- the only angle that shows whether a roof
covers a wall -- beside the existing `22-geleen-wall-at-three-metres`. Then:

Run: `SHOTS=1 bin/rails test test/system/shots_test.rb`
Expected: PASS, and the PNGs written.

- [ ] **Step 2: Look at them**

Open `20-geleen-row-from-the-kerb`, `22`, `25-geleen-gable-end`, `27-geleen-roofs` and the
new eaves shot. Judge from the driver's seat: does the roof cover the wall, is the dakkapel
a window, is there glass with a wall behind it. If any of them still reads wrong, say so in
the report rather than declaring the task done.

- [ ] **Step 3: Write it down**

In `CLAUDE.md`, under the buildings section, add the two rules this phase establishes:
that the eaves overhang is drawing and shares its number with the gutter, and that an
opening never stands in a column another wall lands in, with the 63-of-94 measurement that
motivated it. Note that `classic` is no longer byte-identical and why.

- [ ] **Step 4: Run the full system suite once**

Run: `bin/rails test:system`
Expected: PASS. It takes about seven minutes and holds a machine-wide lock.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "$(cat <<'EOF'
Say how an eaves and an opening are decided, and photograph the roofline

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```
