# Roof Fittings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put a chimney on the ridge, panels on the sun-facing slope, a gutter along every eaves and a downpipe at every corner.

**Architecture:** Three mechanisms, one per thing, chosen by what breaking it should do. Solar panels are a PATCH of a new `solar` material on a roof plane — no new index anywhere. A chimney is four wall SURFACES in a new step 5c of the row order, generated only for a flagged dwelling. Gutters and downpipes are DRAWING: instanced boxes in the `steel` pool, keyed to the cell they hang on and hidden with it, through the attachment store the gable caps introduced.

**Tech Stack:** Rails 8.1, plain Ruby under `app/models/game/`, three.js 0.170 (vendored), Rapier untouched. Minitest; system tests in headless Chrome.

**Spec:** `docs/superpowers/specs/2026-09-19-roof-fittings-design.md`. It follows `2026-09-18-house-details-design.md` (flags, step 5b, gable caps) and `2026-09-18-how-buildings-look-design.md` (looks, patterns, pools).

## Global Constraints

- **Every tuning number lives in Ruby.** Panel size, chimney size, gutter and downpipe section: Ruby constants or spec rules. The client's only new numbers are the ones a painter needs to draw a grid, and those come from the material's `look`.
- **Piece indices are the contract.** A patch never moves an index. Chimney surfaces go in step 5c — right after the dwelling's dormer — and only when flagged, so an unflagged row keeps its numbering byte for byte: the pair is 29 surfaces / 840 pieces, the annex example 34 / 921, `generator_test`'s house 23 / 1553, and `world_summary_test` checks every fixture. `geleen` is re-imported once and the dev database re-seeded with `bin/rails geleen:seed`, never `db:seed`.
- **Draw calls track materials.** Gutters and downpipes are instances in `steel`'s pool. `Building.countMaterials` must count them exactly as `buildFittings` places them — an `InstancedMesh` cannot grow, and a short pool silently drops instances. `street_test` (street ≤ one house) and `building_test` (< 45) stay green.
- **The four hand-made worlds keep their pieces.** Fittings are drawing, so they will appear on `targets`, `street` and `hills` too; that is intended. Nothing about their surfaces changes.
- **The stored normal of a front roof plane points INWARD.** `roof_section` builds both planes with `u = EAST` and `v = up_slope`, so `n = u × v` is `(0, −side·run, rise)`: for `side = +1` (the front plane, at `z0`) that points down into the roof. Never decide "which way does this plane face" from `surface.normal` — derive it from the side and the row's yaw, as Task 2 does.
- **Testing discipline** as before: the named file for what changed; `bin/rails test` and `bin/rubocop` before each commit; no full system suite between tasks; the machine-wide lock. **Before any system test, wait for load**: `sysctl -n vm.loadavg`'s five-minute figure under about 3, polling in a loop for up to 20 minutes — this machine has spent whole hours above 8, and a geleen test flunks its stall detector under load for reasons that are not the code's. The dev server on port 3100 stays up. `node --input-type=module --check < file` with node under `~/.local/share/mise/installs/node/*/bin`.
- **Commits** end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

## Decisions taken here that narrow the spec

- **A chimney's four walls run from the eaves to the ridge plus the rise**, so the lower part is inside the roof and never seen. One height for all four walls keeps the stack a box rather than four staircases.
- **A downpipe goes at the LAST column of every wall surface**, one box per storey. On a row that puts one at each dwelling's party line on the front and at the other end on the back, which is what a terrace has; on a hand-made `building` recipe it puts exactly one at each of the four corners, because each corner is the last column of exactly one edge.
- **A gutter box per column of a roof plane's bottom row**, hung outside the eaves edge. Per column rather than one long box so a gutter disappears in pieces as the roof above it does.
- **Panels go on one plane only** — the sun-facing one — never both, and never on a dormer's top.

## File structure

Ruby:
- `app/models/game/material.rb` — `PATTERNS` gains `panels`.
- `app/models/game/materials.rb` — the `solar` entry.
- `app/models/game/building/row.rb` — `Dwelling` gains `solar`, `chimney`.
- `app/models/game/building/row_generator.rb` — `solar_patch`, `sun_facing_side`, `chimney`, step 5c, the constants.
- `app/models/game/import/rows.rb` — the two flags.

Client:
- `app/javascript/game/render/looks.js` — the `panels` painter.
- `app/javascript/game/world/fittings.js` — NEW. `gutters(surface)`, `downpipes(surface)`, `FITTING_MATERIAL`.
- `app/javascript/game/world/building.js` — `attachments` (renamed from `caps`), `buildFittings`, counting, the readout.
- `app/javascript/game/engine.js` — `__arenaFittings`.

Tests: `test/models/game/materials_test.rb`, `test/models/game/building/row_test.rb`, `test/models/game/import/rows_test.rb`, NEW `test/system/fittings_test.rb`, `test/system/looks_test.rb`, `test/system/shots_test.rb`; `CLAUDE.md`.

---

### Task 1: The `solar` material and the `panels` pattern

**Files:**
- Modify: `app/models/game/material.rb`, `app/models/game/materials.rb`
- Modify: `app/javascript/game/render/looks.js`
- Test: `test/models/game/materials_test.rb`, `test/system/looks_test.rb`

**Interfaces:**
- Produces: `Game::Materials::TABLE[:solar]`; `Material::PATTERNS` gains `"panels"`; `looks.js` `PATTERNS` gains `"panels"` and `PAINTERS.panels`.

- [ ] **Step 1: Write the failing tests**

Append to `test/models/game/materials_test.rb` inside the class:

```ruby
  # A photovoltaic panel: a sheet of glass on an aluminium frame. As easy to break as a
  # window, heavier, holds nothing up, and the same colour on every house -- so it takes no
  # palette role, exactly as glass and steel do not.
  test "a solar panel is glass on a frame and takes no palette" do
    solar = Game::Materials.fetch(:solar)

    assert_nil solar.role
    refute_predicate solar, :structural?
    assert_operator solar.health_per_m2, :<, Game::Materials.fetch(:roof_tile).health_per_m2
    assert_operator solar.density, :>, Game::Materials.fetch(:glass).density * 0.5
    assert_equal "panels", solar.look[:pattern]
    assert_equal 0.0, solar.hardness
  end
```

Append to `test/system/looks_test.rb`, in the high-quality textures test's material list: add `solar` to the `%w[...]` array of materials that must appear in `readout["textured"]`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/models/game/materials_test.rb`
Expected: FAIL — `KeyError: key not found: :solar`.

- [ ] **Step 3: Add the pattern name and the material**

In `app/models/game/material.rb`, extend `PATTERNS`:

```ruby
    PATTERNS = %w[brick tiles planks plaster concrete glass leaves panels].freeze
```

In `app/models/game/materials.rb`, after `roof_tile` and before `steel`:

```ruby
      # A photovoltaic panel: a sheet of glass on an aluminium frame, lying on the tiles.
      # As easy to break as a window and rather heavier, holding nothing up. No palette
      # role -- a panel is the same near-black on every house, and a red-brick terrace with
      # red panels would be a strange sight.
      solar: Material.new(
        name: :solar, colour: "#1b2530",
        health_per_m2: 0.6, density: 1600.0,
        structural_weight: 0.0,
        multipliers: { impact: 2.4, blast: 2.2, blade: 1.8, bull_bar: 1.8, slam: 1.8 },
        fracture: { method: "voronoi", mode: "2.5D", fragments: 14, project_along_normal: true },
        friction: 0.4, restitution: 0.08,
        metalness: 0.3, roughness: 0.25,
        chunk: { size: [ 0.45, 0.04, 0.35 ], vary: 0.40, jitter: 0.35 },
        # A near-black field divided into cells, with a lighter frame round each module.
        # `unit` is the cell and the module: 0.16 m cells inside a 1 m module.
        look: { pattern: "panels", unit: [ 0.16, 1.0 ], joint: 0.008, joint_shade: 1.6,
                variation: 0.05, relief: 0.25, base: "#e8ecf2" }
      ),
```

Note `joint_shade` above 1 on purpose: a panel's grid lines and frame are LIGHTER than its cells, where brick's mortar is darker. The painter multiplies, so a shade over one brightens.

- [ ] **Step 4: Paint it**

In `app/javascript/game/render/looks.js`, add `"panels"` to `PATTERNS`, add `panels` to the `PAINTERS` map, and write the painter beside `tiles`:

```js
// Photovoltaic cells: a dark field divided into small squares by light busbars, with a
// brighter frame at each module's edge. `unit` is [cell, module] in metres; the module
// frame is what stops a roof of panels reading as one black rectangle.
function panels(ctx, hctx, rctx, look, spec) {
  const cells = perTile(look.unit[0])
  const modules = perTile(look.unit[1])
  const cw = SIZE / cells
  const mw = SIZE / modules
  const line = Math.max(1, look.joint * PX)
  // The field is the dark one here: the base is the LIGHT busbar colour and the cells are
  // it multiplied down, which is the opposite way round from brick and is why joint_shade
  // is above one rather than below.
  fill(ctx, shade(look.base, 1 / look.joint_shade))
  fill(hctx, grey(0.9))
  fill(rctx, grey(spec.roughness ?? 0.25))
  for (let r = 0; r < cells; r += 1) {
    for (let c = 0; c < cells; c += 1) {
      const value = 1 + (noise(r, c, 10) - 0.5) * 2 * look.variation
      box(ctx, shade(look.base, value / look.joint_shade), c * cw + line, r * cw + line, cw - 2 * line, cw - 2 * line)
      box(hctx, grey(0.55), c * cw + line, r * cw + line, cw - 2 * line, cw - 2 * line)
    }
  }
  // The module frame, over the cells: two bands per module edge, in the base colour.
  for (let m = 0; m <= modules; m += 1) {
    box(ctx, look.base, m * mw - line, 0, 2 * line, SIZE)
    box(ctx, look.base, 0, m * mw - line, SIZE, 2 * line)
    box(hctx, grey(1.0), m * mw - line, 0, 2 * line, SIZE)
    box(hctx, grey(1.0), 0, m * mw - line, SIZE, 2 * line)
  }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/models/game/materials_test.rb && bin/rails test && bin/rubocop`
Expected: PASS. `node --input-type=module --check < app/javascript/game/render/looks.js` clean.

Wait for load, then run: `bin/rails test test/system/looks_test.rb`
Expected: PASS — `solar` appears in `textured` and in `normals` at high, and the high boot has no console errors (a painter that throws would show there).

- [ ] **Step 6: Commit**

```bash
git add app/models/game/material.rb app/models/game/materials.rb app/javascript/game/render/looks.js test/models/game/materials_test.rb test/system/looks_test.rb
git commit -m "Add a solar panel to the table, and paint its cells and its frame

Glass's fragility with more mass, no palette role -- a panel is the same near-black on
every house -- and a panels pattern whose joints are lighter than its field, which is
the first look in the table that brightens rather than darkens.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Panels on the sun-facing plane

**Files:**
- Modify: `app/models/game/building/row.rb`
- Modify: `app/models/game/building/row_generator.rb`
- Test: `test/models/game/building/row_test.rb`

**Interfaces:**
- Consumes: `Materials.fetch(:solar)` (Task 1).
- Produces: `Row::Dwelling` gains `solar`, `chimney` (booleans, default false, recipe keys `"solar"`, `"chimney"`); `RowGenerator.sun_facing_side(yaw)` → `+1` or `-1`; `RowGenerator::SOLAR_COLS = 4`, `SOLAR_ROWS = 2`, `SOLAR_INSET = 1`; `roof_section` patches the sun-facing plane.

- [ ] **Step 1: Write the failing tests**

Append to `test/models/game/building/row_test.rb` inside the class:

```ruby
  # Game +z is SOUTH: Frame#to_game negates RD north. In the row's own frame the back plane
  # (side -1, standing at z1) faces +z and the front plane (side +1, at z0) faces -z, and a
  # rotation by yaw sends local +z to a world z of cos(yaw). So the back plane is the
  # sun-facing one exactly when cos(yaw) is positive.
  test "the sun-facing plane is the one the yaw points south" do
    assert_equal(-1, Game::Building::RowGenerator.sun_facing_side(0.0), "a row facing north puts them on its back")
    assert_equal(-1, Game::Building::RowGenerator.sun_facing_side(1.0))
    assert_equal 1, Game::Building::RowGenerator.sun_facing_side(Math::PI), "a row facing south puts them on its front"
    assert_equal 1, Game::Building::RowGenerator.sun_facing_side(2.5)
  end

  # A patch, not a surface: the panels replace roof cells and move no index at all.
  test "a flagged dwelling gets one rectangle of panels on its sun-facing plane" do
    set = pair("dwellings" => [ { "x0" => 0.0, "x1" => 6.0, "solar" => true }, { "x0" => 6.0, "x1" => 12.0 } ])

    assert_equal 29, set.surfaces.length, "a patch adds no surface"
    assert_equal 840, set.piece_count, "and no piece"
    planes = set.surfaces.select { |s| s.kind == :roof }
    front, back = planes[0], planes[1]
    assert_empty front.patches, "yaw 0 faces north, so the front plane keeps its tiles"
    panels = back.patches.select { |p| p.material == :solar }
    assert_equal 1, panels.length
    patch = panels.first
    # The plane is 6.4 x 5.148 m at 1 m cells -> 6 columns, 5 rows. Inset one cell leaves
    # columns 1..4 and rows 1..3; four wide fills the columns exactly, two tall is centred
    # on the three rows, which puts it on rows 1..2.
    assert_equal [ 1, 4 ], [ patch.col0, patch.col1 ]
    assert_equal [ 1, 2 ], [ patch.row0, patch.row1 ]
    # The neighbour is unflagged and keeps a bare roof.
    assert_empty planes[3].patches
  end

  test "a flagged dwelling with no room gets no panels, and a flat roof never does" do
    # A 3 m dwelling: the plane is 3.4 m -> 3 columns, and the inset leaves one.
    narrow = pair("dwellings" => [ { "x0" => 0.0, "x1" => 3.0, "solar" => true }, { "x0" => 3.0, "x1" => 12.0 } ])
    assert_empty narrow.surfaces.select { |s| s.kind == :roof }[1].patches

    flat = pair("roof" => "flat", "ridge" => 6.0, "dwellings" => [ { "x0" => 0.0, "x1" => 6.0, "solar" => true }, { "x0" => 6.0, "x1" => 12.0 } ])
    assert_empty flat.surfaces.select { |s| s.kind == :roof }.flat_map(&:patches)
  end

  test "panels turn with the row rather than following it" do
    # At yaw pi the row faces south, so the panels move to the front plane -- the same
    # dwelling, the other slope.
    turned = pair("yaw" => Math::PI, "dwellings" => [ { "x0" => 0.0, "x1" => 6.0, "solar" => true }, { "x0" => 6.0, "x1" => 12.0 } ])
    planes = turned.surfaces.select { |s| s.kind == :roof }

    assert_equal 1, planes[0].patches.count { |p| p.material == :solar }
    assert_empty planes[1].patches
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/models/game/building/row_test.rb -n "/sun-facing|panels/"`
Expected: FAIL — `NoMethodError: undefined method 'sun_facing_side'`, and no patches on any plane.

- [ ] **Step 3: Two more flags on a dwelling**

In `app/models/game/building/row.rb`, extend the struct and its parsing exactly as `garage`/`glazing`/`dormer` are done — add `:solar, :chimney` to `Dwelling`, `solar: d.fetch("solar", false), chimney: d.fetch("chimney", false)` in `from`, and add both to the boolean validation loop's array.

- [ ] **Step 4: Patch the sun-facing plane**

In `app/models/game/building/row_generator.rb`, add the constants beside the dormer's:

```ruby
      # A solar array: at most this many cells across and up, inset this far from every edge
      # of the plane so the array never runs into the ridge, the eaves or the verge.
      SOLAR_COLS = 4
      SOLAR_ROWS = 2
      SOLAR_INSET = 1
```

Add, after `roof_section`:

```ruby
      # Which of the two roof planes faces the sun, as the `side` roof_section builds them
      # with. Game +z is SOUTH -- Terrain::Frame#to_game negates RD north -- and in the
      # row's own frame the back plane (side -1) faces +z while the front (side +1) faces
      # -z; a rotation by yaw sends local +z to a world z of cos(yaw). So the back plane
      # is the sun-facing one exactly when cos(yaw) is positive.
      #
      # Derived from the yaw and never from `surface.normal`: both planes are built with
      # u = EAST, so the front plane's u x v points INTO the roof and the two normals do
      # not mean the same thing.
      def self.sun_facing_side(yaw)
        Math.cos(yaw).positive? ? -1 : 1
      end

      # The panels, as a patch of `solar` cells centred on the plane and inset from its
      # edges. A patch, so a roof of panels is the same surfaces and the same indices as a
      # roof of tiles -- and a broken panel is a broken roof cell, which is what it is.
      def self.solar_patch(cols, rows)
        across = cols - 2 * SOLAR_INSET
        up = rows - 2 * SOLAR_INSET
        return nil if across < 1 || up < 1

        width = [ SOLAR_COLS, across ].min
        height = [ SOLAR_ROWS, up ].min
        col0 = SOLAR_INSET + (across - width) / 2
        row0 = SOLAR_INSET + (up - height) / 2
        Surface::Patch.new(col0: col0, row0: row0, col1: col0 + width - 1, row1: row0 + height - 1, material: :solar)
      end
```

and in `roof_section`, inside the `planes = [ 1, -1 ].map do |side|` block, compute the patches before building the surface:

```ruby
        sun = sun_facing_side(row.yaw)
        planes = [ 1, -1 ].map do |side|
          origin = Vector3.new(start, row.eaves, side.positive? ? row.z0 : row.z1)
          up_slope = Vector3.new(0.0, row.rise, side * run)
          cols = Walls.cells(span, row.cell)
          rows = Walls.cells(slope, row.cell)
          # Panels on the sun-facing slope of a flagged dwelling, and on nothing else.
          panels = d.solar && side == sun ? Array(solar_patch(cols, rows)) : []
          Surface.new(
            kind: :roof, storey: row.storeys, material: Materials.fetch(:roof_tile),
            origin: origin, u: EAST, v: up_slope.normalised, width: span, height: slope,
            cols: cols, rows: rows, thickness: Roof::THICKNESS, patches: panels, bay: i
          )
        end
```

(The flat-roof branch returns before this, so a flat roof gets none.)

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/models/game/building/row_test.rb test/models/game/building/generator_test.rb`
Expected: PASS, worked examples unchanged. If the pinned columns differ, print `set.surfaces.select { |s| s.kind == :roof }.map { |s| [s.cols, s.rows, s.patches.map(&:to_spec)] }` and correct the literal from the geometry — the derivation in the test's comment is the contract.

- [ ] **Step 6: Run the model suite and commit**

```bash
bin/rails test && bin/rubocop
git add app/models/game/building/row.rb app/models/game/building/row_generator.rb test/models/game/building/row_test.rb
git commit -m "Put panels on the slope that faces the sun, as a patch of solar cells

A patch, so a roof of panels is the same surfaces and the same indices as a roof of
tiles. Which slope faces the sun comes from the row's yaw -- game +z is south -- and
never from the plane's own normal, which points into the roof on the front side.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Chimneys, step 5c

**Files:**
- Modify: `app/models/game/building/row_generator.rb`
- Test: `test/models/game/building/row_test.rb`

**Interfaces:**
- Consumes: `Dwelling#chimney` (Task 2).
- Produces: `RowGenerator.chimney(row, d, i)` → 0 or 4 `Surface`s (`:wall`, `brick`, `storey: row.storeys`, `bay: i`); constants `CHIMNEY_SIDE = 0.9`, `CHIMNEY_RISE = 1.2`. Step 5c in the order.

- [ ] **Step 1: Write the failing tests**

Append to `test/models/game/building/row_test.rb`:

```ruby
  # STEP 5c OF THE CONTRACT. A chimney is four walls right after its dwelling's dormer.
  # Worked by hand from the pair with a chimney on the first dwelling: the stack is 0.9 m
  # square on the ridge at x = 6 (the party line), so its ring runs x 5.55..6.45 and
  # z 4.05..4.95; each wall is Walls.cells(0.9, 1) = 1 column. It stands from the eaves at
  # 6.0 to the ridge at 8.5 plus 1.2 = 9.7, so 3.7 m -> 4 rows. Four walls of 4 cells is 16,
  # appended after the first gable ends at 654 + 27 = 681, which moves the second dwelling's
  # roof from 681 to 697 and the rubble from 768 to 784: 840 -> 856 pieces, 29 -> 33 surfaces.
  test "a chimney is four walls right after its dwelling's dormer" do
    set = pair("dwellings" => [ { "x0" => 0.0, "x1" => 6.0, "chimney" => true }, { "x0" => 6.0, "x1" => 12.0 } ])

    assert_equal 33, set.surfaces.length
    assert_equal 856, set.piece_count
    assert_equal [ 0, 18, 36, 54, 72, 90, 108, 126, 144, 171, 198, 225, 252, 279,
                   306, 360, 414, 432, 450, 504, 558, 576, 594, 624, 654,
                   681, 685, 689, 693, 697, 727, 757, 784 ],
                 set.surfaces.map(&:piece_offset)
    stack = set.surfaces[25, 4]
    assert_equal %i[wall] * 4, stack.map(&:kind)
    assert_equal [ :brick ] * 4, stack.map { |s| s.material.name }
    assert_equal [ 2 ] * 4, stack.map(&:storey), "above every storey, like the roof it stands on"
    assert_equal [ 0 ] * 4, stack.map(&:bay)
    assert_equal [ 1 ] * 4, stack.map(&:cols)
    assert_equal [ 4 ] * 4, stack.map(&:rows)
    assert_in_delta 6.0, stack.map { |s| s.origin.x }.sum / 4, 1e-9, "centred on the party line"
    assert_in_delta 4.5, stack.map { |s| s.origin.z }.sum / 4, 1e-9, "on the ridge"
    assert_in_delta 6.0, stack.first.origin.y, 1e-9, "standing at the eaves, its foot inside the roof"
    assert_in_delta 3.7, stack.first.height, 1e-9
  end

  test "no chimney on a flat roof, on a narrow dwelling, or on an unflagged one" do
    assert_equal 840, pair.piece_count
    flat = pair("roof" => "flat", "ridge" => 6.0, "dwellings" => [ { "x0" => 0.0, "x1" => 6.0, "chimney" => true }, { "x0" => 6.0, "x1" => 12.0 } ])
    assert_empty flat.surfaces.select { |s| s.storey == 2 && s.kind == :wall }
    narrow = pair("dwellings" => [ { "x0" => 0.0, "x1" => 1.5, "chimney" => true }, { "x0" => 1.5, "x1" => 12.0 } ])
    assert_empty narrow.surfaces.select { |s| s.storey == 2 && s.kind == :wall }
  end

  test "a chimney falls with its dwelling" do
    set = pair("dwellings" => [ { "x0" => 0.0, "x1" => 6.0, "chimney" => true }, { "x0" => 6.0, "x1" => 12.0 } ])

    assert_equal 4, set.for_bay(0)[:own].count { |s| s.storey == 2 && s.kind == :wall }
    assert_equal 0, set.for_bay(1)[:own].count { |s| s.storey == 2 && s.kind == :wall }
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/models/game/building/row_test.rb -n "/chimney/"`
Expected: FAIL — 29 surfaces and 840 pieces where 33 and 856 were expected.

- [ ] **Step 3: Generate the chimney**

In `app/models/game/building/row_generator.rb`, update the header comment's order to `… 5 roof sections, 5b dormers, 5c chimneys, 6 boxes, 7 hedges, rubble LAST`, extend the dwellings line:

```ruby
        row.dwellings.each_with_index { |d, i| built.concat roof_section(row, d, i); built.concat dormer(row, d, i); built.concat chimney(row, d, i) }
```

and add, after `dormer`:

```ruby
      # A chimney: a square brick stack on the ridge, at the dwelling's party-line end --
      # which is where a terrace's flues actually run, and why the chimneys of a real row
      # come in pairs down the roof.
      CHIMNEY_SIDE = 0.9
      CHIMNEY_RISE = 1.2

      # 5c. Four walls, or none. The stack runs from the EAVES to the ridge plus the rise,
      # so its foot is buried in the roof and its four walls are one height rather than
      # four staircases; the buried part is never seen, and a cell inside a roof costs an
      # index that the alternative -- clipping each wall to the pitch -- would spend on
      # geometry nobody looks at.
      def self.chimney(row, d, i)
        return [] unless d.chimney && row.roof == "gable" && d.width >= 2 * CHIMNEY_SIDE

        half = CHIMNEY_SIDE / 2.0
        # The party-line end for every dwelling but the last, which puts its stack at the
        # end it shares with nobody -- half a metre in, so it stands on the roof and not on
        # the verge.
        last = i == row.dwellings.length - 1
        cx = last ? d.x1 - half - 0.5 : d.x1
        cz = (row.z0 + row.z1) / 2.0
        height = row.ridge + CHIMNEY_RISE - row.eaves
        rows = [ Walls.cells(height, row.cell), 1 ].max
        corners = [ [ cx - half, cz - half ], [ cx + half, cz - half ], [ cx + half, cz + half ], [ cx - half, cz + half ] ]

        corners.each_with_index.map do |from, e|
          to = corners[(e + 1) % 4]
          along = Vector3.new(to[0] - from[0], 0.0, to[1] - from[1])
          Surface.new(
            kind: :wall, storey: row.storeys, material: Materials.fetch(:brick),
            origin: Vector3.new(from[0], row.eaves, from[1]), u: along.normalised, v: UP,
            width: along.length, height: height, cols: Walls.cells(along.length, row.cell), rows: rows,
            thickness: Walls::THICKNESS, seed: row.seed + 400 + i, bay: i
          )
        end
      end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/models/game/building/row_test.rb`
Expected: PASS. If the offsets differ, print what the generator emitted and correct the literal against the derivation in the comment.

- [ ] **Step 5: Run the model suite and commit**

```bash
bin/rails test && bin/rubocop
git add app/models/game/building/row_generator.rb test/models/game/building/row_test.rb
git commit -m "Stand a chimney on the ridge at the party line, in step 5c

Four brick walls from the eaves to the ridge plus its rise, so the stack is a box and
the buried part costs nothing to look at. An unflagged row keeps every index it had.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Gutters and downpipes

**Files:**
- Create: `app/javascript/game/world/fittings.js`
- Modify: `app/javascript/game/world/building.js`
- Modify: `app/javascript/game/engine.js`
- Test: `test/system/fittings_test.rb` (new); `test/system/gables_test.rb`, `building_test.rb`, `street_test.rb` stay green

**Interfaces:**
- Produces: `fittings.js` exports `FITTING_MATERIAL = "steel"`, `GUTTER_SIDE = 0.12`, `gutters(surface)` → `[{ row, col, along, cross, drop, length }]` and `downpipes(surface)` → `[{ row, col, … }]`, each entry describing one box in the surface's own `(u, v, n)` frame as `{ anchorRow, anchorCol, u0, v0, du, dv, dn, su, sv, sn }` (centre offsets and scales along the three axes). `Building`: `this.caps` renamed `this.attachments`, `buildCaps` → `buildGableCaps`, plus `buildFittings`, `showAttachments`, and `capReadout` gains `gutters`, `downpipes`, `fittingPools`. Hook `__arenaFittings(buildingId)`.

- [ ] **Step 1: Write the failing system test**

Create `test/system/fittings_test.rb`:

```ruby
require "application_system_test_case"

# The rainwater goods: a gutter along every eaves and a downpipe at every corner. Drawing
# rather than pieces -- 120 mm of folded zinc is not worth an index -- so what the tests
# assert is that each one hangs on a cell and goes when that cell goes.
class FittingsTest < ApplicationSystemTestCase
  def boot
    visit_world("targets", match: "fittings")
    wait_for(message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
    page.evaluate_script("window.__arenaBuildingIds()[0]")
  end

  def fittings(building) = page.evaluate_script("window.__arenaFittings(arguments[0])", building)

  # The targets house has two roof planes of 16 columns and four walls of three storeys.
  test "every eaves column has a gutter and every wall end a downpipe" do
    building = boot
    readout = fittings(building)

    assert_equal 32, readout["gutters"], "one per column of each plane's bottom row"
    assert_equal 12, readout["downpipes"], "one per storey at the last column of each of the four walls"
    assert_equal 1, readout["fittingPools"], "zinc is steel's pool, and there is only the one"
    assert_equal readout["gutters"] + readout["downpipes"], readout["shownFittings"]
  end

  test "a fitting goes with the cell it hangs on and comes back with it" do
    building = boot
    before = fittings(building)["shownFittings"]
    cell = page.evaluate_script(<<~JS, building)
      (() => {
        const spec = window.__arenaBuildingSpec(arguments[0])
        const plane = spec.surfaces.find(s => s.kind === "roof")
        // The bottom row's middle column: a gutter hangs on it.
        return plane.off + Math.floor(plane.cols / 2)
      })()
    JS

    page.execute_script("window.__arenaBreak(arguments[0], arguments[1])", cell, building)
    assert_operator fittings(building)["shownFittings"], :<, before, "breaking the eaves cell hid no gutter"

    page.execute_script("window.__arenaRestore(arguments[0], arguments[1])", cell, building)
    assert_equal before, fittings(building)["shownFittings"], "restoring it brought no gutter back"
  end

  test "the fittings cost no draw call of their own" do
    boot
    page.driver.browser.action.key_down("g").key_up("g").perform
    wait_for(message: "debug view never hid") { page.evaluate_script("window.__arenaDebugVisible") == false }
    sleep 0.3
    assert_operator page.evaluate_script("window.__arenaDraws()"), :<, 45
  end
end
```

The counts in the first test are derived, not guessed: the targets house is 12 × 15 m at 1 m cells with the ridge along z, so each plane spans `15 + 2 × 0.4 = 15.8` m → 16 columns, and there are two planes; four wall edges × three storeys gives twelve pipes. Verify before trusting: `bin/rails runner 'set = WorldObject.find_by(name: "house").surface_set; puts set.surfaces.select { |s| s.kind == :roof }.map(&:cols).inspect; puts set.surfaces.count { |s| s.kind == :wall }'`.

- [ ] **Step 2: Run the test to verify it fails**

Run (after the load gate): `bin/rails test test/system/fittings_test.rb`
Expected: FAIL — `__arenaFittings is not a function`.

- [ ] **Step 3: Write `fittings.js`**

Create `app/javascript/game/world/fittings.js`:

```js
// The rainwater goods: a gutter along every eaves and a downpipe at every corner.
//
// DRAWING, not pieces, for the same reason the gable caps are: a gutter is 120 mm of folded
// zinc, and giving it its own indices would add a surface per roof plane and a surface per
// wall to every building in the world for something the player can only ever look at. Each
// box is keyed to the cell it hangs on, hidden when that cell breaks and restored with it,
// through the same attachment store the caps use. No colliders -- a car that hits a
// downpipe is hitting the wall behind it, and the wall is what breaks.
//
// Every box is described in its surface's own frame -- offsets along u, v and the normal,
// and a size on each -- so the caller composes one matrix the same way for both kinds.

// Zinc. `steel` is what the dormer's top already uses, and a second grey metal in the table
// would be a second pool for no difference anyone can see.
export const FITTING_MATERIAL = "steel"
// The section of a gutter and of a downpipe, in metres. Square: a half-round gutter and a
// round pipe are a lathe's worth of triangles each, at this size, for nothing.
export const GUTTER_SIDE = 0.12

// One gutter box per column of a roof plane's bottom row, hung just below the eaves edge
// and just outside it, so it sits under the tiles' lip rather than in them.
export function gutters(surface) {
  if (surface.kind !== "roof") return []

  const width = surface.w / surface.cols
  const out = []
  for (let col = 0; col < surface.cols; col += 1) {
    out.push({
      anchorRow: 0,
      anchorCol: col,
      // Centred on its column, half a section below the plane's lower edge, and half a
      // section proud of the plane's own face.
      u0: (col + 0.5) * width,
      v0: -GUTTER_SIDE / 2,
      n0: GUTTER_SIDE / 2 + surface.t / 2,
      su: width,
      sv: GUTTER_SIDE,
      sn: GUTTER_SIDE
    })
  }
  return out
}

// One downpipe box per storey at the LAST column of a wall, which on a row puts a pipe at
// every party line and on a hand-made building exactly one at each corner -- each corner is
// the last column of exactly one edge.
export function downpipes(surface) {
  if (surface.kind !== "wall") return []

  const width = surface.w / surface.cols
  const col = surface.cols - 1
  return [ {
    anchorRow: 0,
    anchorCol: col,
    // Against the far end of the wall and proud of its face, running its whole height.
    u0: surface.w - GUTTER_SIDE / 2,
    v0: surface.h / 2,
    n0: GUTTER_SIDE / 2 + surface.t / 2,
    su: GUTTER_SIDE,
    sv: surface.h,
    sn: GUTTER_SIDE
  } ]
}

// Every fitting of a surface, whatever kind it is.
export function fittingsFor(surface) {
  return [ ...gutters(surface), ...downpipes(surface) ]
}
```

- [ ] **Step 4: Place and count them**

In `app/javascript/game/world/building.js`:

Rename throughout: `this.caps` → `this.attachments`, `buildCaps` → `buildGableCaps`, `showCaps` → `showAttachments`. (`capReadout` keeps its name and gains fields; `gables_test` reads it.)

Import `fittingsFor, FITTING_MATERIAL` from `game/world/fittings`.

In `countMaterials`, after the gable block:

```js
      // The rainwater goods hang on the cells of roofs and walls. Counted here exactly as
      // buildFittings places them, because an InstancedMesh cannot grow and a short pool
      // drops instances without a word.
      const fittings = fittingsFor(surface).length
      if (fittings) into.set(FITTING_MATERIAL, (into.get(FITTING_MATERIAL) || 0) + fittings)
```

In `build`, beside the gable loop:

```js
    for (const surface of this.spec.surfaces) {
      if (surface.kind === "gable") this.buildGableCaps(surface)
      this.buildFittings(surface)
    }
```

and the method, beside `buildGableCaps`:

```js
  // A box per fitting, in the surface's own frame, keyed to the cell it hangs on.
  buildFittings(surface) {
    const boxes = fittingsFor(surface)
    if (boxes.length === 0) return

    const u = new THREE.Vector3().fromArray(surface.u)
    const v = new THREE.Vector3().fromArray(surface.v)
    const n = new THREE.Vector3().fromArray(surface.n)
    const origin = new THREE.Vector3().fromArray(surface.o).add(this.origin)

    for (const box of boxes) {
      const index = surface.off + box.anchorRow * surface.cols + box.anchorCol
      // A fitting on a cell that was never built -- a void doorway, a clipped corner -- has
      // nothing to hang on and nothing to disappear with, so it is not drawn at all.
      if (this.state[index] === ABSENT) continue

      CAP_MATRIX.makeBasis(u, v, n)
      CAP_MATRIX.scale(CAP_SCALE.set(box.su, box.sv, box.sn))
      CAP_MATRIX.setPosition(
        CAP_POSITION.copy(origin).addScaledVector(u, box.u0).addScaledVector(v, box.v0).addScaledVector(n, box.n0)
      )
      const entry = this.attachments[index] || (this.attachments[index] = { pools: [], slots: [], matrices: [], fittings: 0 })
      entry.pools.push(FITTING_MATERIAL)
      entry.slots.push(this.meshes.add(FITTING_MATERIAL, CAP_MATRIX, this.tintFor(FITTING_MATERIAL, index), 0, 0))
      entry.matrices.push(CAP_MATRIX.clone())
      entry.fittings += 1
    }
  }
```

Note `countMaterials` counts every fitting while `buildFittings` skips the ones on `ABSENT` cells, so the pool is over-allocated rather than short — the safe direction, and the same asymmetry the caps already have.

Extend `capReadout` to also report, by walking `this.spec.surfaces` with `gutters`/`downpipes` for the totals and the attachments for what is showing:

```js
    let fittingsShown = 0
    const fittingPools = new Set()
    for (const entry of this.attachments) {
      if (!entry?.fittings) continue
      for (let k = entry.pools.length - entry.fittings; k < entry.pools.length; k += 1) {
        fittingPools.add(entry.pools[k])
        if (this.meshes.isVisible(entry.pools[k], entry.slots[k])) fittingsShown += 1
      }
    }
    let gutterCount = 0
    let downpipeCount = 0
    for (const surface of this.spec.surfaces) {
      gutterCount += gutters(surface).length
      downpipeCount += downpipes(surface).length
    }
```

and return them as `gutters: gutterCount, downpipes: downpipeCount, fittingPools: fittingPools.size, shownFittings: fittingsShown` alongside the cap fields. Import `gutters, downpipes` too. (Fittings are pushed after any caps on the same index, which is why the loop counts from the end; a gable cell can carry both.)

In `app/javascript/game/engine.js`, beside `__arenaGableCaps`:

```js
    // The rainwater goods: how many the building hung, how many are showing, and how many
    // pools they cost. Drawing, like the caps -- a test proves one goes by breaking the
    // cell it hangs on.
    window.__arenaFittings = (buildingId) => this.buildings?.find(buildingId)?.capReadout() ?? null
```

- [ ] **Step 5: Run the tests**

`node --input-type=module --check` both JS files. Then, after the load gate:

Run: `bin/rails test test/system/fittings_test.rb test/system/gables_test.rb`
Expected: PASS. If the gutter count is not 32, print the roof planes' `cols` with the runner line from Step 1 and correct the literal.

Run: `bin/rails test test/system/building_test.rb test/system/street_test.rb`
Expected: PASS.

- [ ] **Step 6: Look, then commit**

`SHOTS=1 bin/rails test test/system/shots_test.rb -n test_photograph_the_house`, then look at `tmp/shots/01-house.png` and `02-wall-close.png`: a gutter should run the length of each eaves, a pipe down each corner, and neither should float off the wall or cut into it. Describe honestly.

```bash
git add app/javascript/game/world/fittings.js app/javascript/game/world/building.js app/javascript/game/engine.js test/system/fittings_test.rb
git commit -m "Hang a gutter on every eaves and a downpipe at every corner

Drawing rather than pieces, keyed to the cell each one hangs on and hidden with it,
in the pool steel already has. The store the gable caps introduced is renamed from
caps to attachments, because it is no longer only caps.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: The importer flags them, and geleen is re-imported

**Files:**
- Modify: `app/models/game/import/rows.rb`
- Regenerate: `test/fixtures/{worlds,world_objects}/geleen.yml`
- Test: `test/models/game/import/rows_test.rb`

**Interfaces:**
- Produces: recipe keys `solar` and `chimney` on dwellings; `Rows::SOLAR_SHARE = 30`, `CHIMNEY_SHARE = 55`.

- [ ] **Step 1: Write the failing tests**

Append to `test/models/game/import/rows_test.rb`:

```ruby
  test "dwellings are flagged for panels and chimneys by seed, where the roof allows" do
    dwellings = (rows.objects + church_rows.objects).flat_map { |o| o[:recipe]["dwellings"].map { |d| [ o, d ] } }
    %w[solar chimney].each do |flag|
      flagged = dwellings.count { |_, d| d[flag] }
      assert_operator flagged, :>, 0, "no dwelling has #{flag}"
      assert_operator flagged, :<, dwellings.length, "every dwelling has #{flag}"
    end
    dwellings.each do |o, d|
      next unless d["solar"] || d["chimney"]

      assert_equal "gable", o[:recipe]["roof"], "#{o[:name]}: fittings on a flat roof"
      assert_includes %w[house apartments], o[:category], "#{o[:name]}: fittings on a #{o[:category]}"
      assert_operator d["x1"] - d["x0"], :>=, 1.8, "#{o[:name]}: a chimney on a dwelling narrower than its stack" if d["chimney"]
    end
  end

  test "every flagged recipe generates its fittings" do
    (rows.objects + church_rows.objects).each do |o|
      set = Game::Building::Generator.call(o[:recipe])
      chimneys = o[:recipe]["dwellings"].count { |d| d["chimney"] }
      stacks = set.surfaces.count { |s| s.kind == :wall && s.storey == o[:recipe]["storeys"] }
      assert_equal chimneys * 4, stacks, "#{o[:name]}: a flagged chimney was not generated"
      panels = o[:recipe]["dwellings"].count { |d| d["solar"] }
      next if panels.zero?

      assert_operator set.surfaces.count { |s| s.patches.any? { |p| p.material == :solar } }, :>, 0, "#{o[:name]}: no panels"
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/models/game/import/rows_test.rb`
Expected: FAIL — no dwelling carries either flag.

- [ ] **Step 3: Flag them**

In `app/models/game/import/rows.rb`, add beside the other shares:

```ruby
      # Panels went up across estates like this one through the 2010s; chimneys were built
      # with the houses, so nearly every party line has one.
      SOLAR_SHARE = 30
      CHIMNEY_SHARE = 55
```

and in the flags block, beside the dormer line (salts 4 and 5, the next two free):

```ruby
              d["solar"] = true if lived_in && recipe["roof"] == "gable" && self.class.detail?(seed, i, 4, SOLAR_SHARE)
              d["chimney"] = true if lived_in && recipe["roof"] == "gable" && width >= 2 * Building::RowGenerator::CHIMNEY_SIDE && self.class.detail?(seed, i, 5, CHIMNEY_SHARE)
```

- [ ] **Step 4: Run the tests, re-import, re-seed**

Run: `bin/rails test test/models/game/import/rows_test.rb`
Expected: PASS.

```bash
bin/rails geleen:import
git diff --stat test/fixtures
git diff test/fixtures/world_objects/geleen.yml | grep -c "^+      solar: true"
git diff test/fixtures/world_objects/geleen.yml | grep -c "^+      chimney: true"
bin/rails geleen:seed
bin/rails runner 'puts WorldObject.where(world: World["geleen"]).sum(:piece_count)'
```

Expected: `terrain_tiles/geleen.yml` unchanged (leave it out of the commit if only its date moved); `worlds/geleen.yml` only its digest; `piece_count` grows only on rows with chimneys, by 4 × the stack's rows per chimney; the panels move nothing. Record the two counts, the total and the digest in your report.

- [ ] **Step 5: Run the model suite and the imported world's system files, then commit**

```bash
bin/rails test && bin/rubocop
```
Then, after the load gate: `bin/rails test test/system/geleen_test.rb test/system/bays_test.rb`

```bash
git add app/models/game/import/rows.rb test/models/game/import/rows_test.rb test/fixtures/worlds/geleen.yml test/fixtures/world_objects/geleen.yml
git commit -m "Flag the estate's dwellings for panels and chimneys, and re-import

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Document it, photograph it, prove nothing regressed

**Files:**
- Modify: `CLAUDE.md`, `test/system/shots_test.rb`

- [ ] **Step 1: Document**

In `CLAUDE.md`, under "How buildings look", after the dwelling-flags bullet:

```markdown
- **Three mechanisms for three kinds of fitting, chosen by what breaking one should do.**
  A solar array is a PATCH of `solar` cells on the sun-facing roof plane — it breaks with
  the roof cell it replaces and moves no index at all. A chimney is PIECES: four brick
  walls from the eaves to the ridge plus its rise, at the dwelling's party line, **step 5c
  of the order**. A gutter and a downpipe are DRAWING, instanced boxes in `steel`'s pool
  keyed to the cell they hang on and hidden with it, through the same attachment store the
  gable caps use (`Building#buildFittings`) — 120 mm of folded zinc is not worth an index.
  Which slope faces the sun comes from the row's yaw and never from the plane's own normal:
  game +z is south, and `roof_section` builds both planes with `u = EAST`, so the front
  plane's `u × v` points INTO the roof.
```

Update the `geleen` bullet's numbers from Task 5's report (pieces, panels, chimneys), the "Rows and bays" order bullet to include step 5c, and add `__arenaFittings` to the hooks table.

- [ ] **Step 2: Photograph**

In `test/system/shots_test.rb`'s "photograph geleen", after the gable shot:

```ruby
    # From above the kerb, where a roof is actually visible: the panels, the chimneys and
    # the gutter line all live up there and none of them shows from the driver's seat.
    park_in_front_of(row, back: 14, y: 9.0)
    shot "27-geleen-roofs"
```

`park` already takes `y:`; pass it through `park_in_front_of` (add the keyword and forward it). Then `SHOTS=1 bin/rails test test/system/shots_test.rb -n test_photograph_geleen` after the load gate, and look at 20, 25 and 27: chimneys on the ridges, panels on the sun-facing slopes only, a gutter line along the eaves, pipes at the party lines. Describe each honestly, including anything that looks wrong.

- [ ] **Step 3: Checks**

```bash
bin/rails test
bin/rubocop
```
then, after the load gate:
```bash
bin/rails test test/system/fittings_test.rb test/system/gables_test.rb test/system/looks_test.rb test/system/geleen_test.rb test/system/bays_test.rb test/system/street_test.rb test/system/building_test.rb test/system/collapse_test.rb
```
Do not run the whole system suite; the controller does that once.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md test/system/shots_test.rb
git commit -m "Say how a fitting is drawn or built, and photograph the roofs

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Self-review

- **Spec coverage.** §1 the three mechanisms → Tasks 2, 3, 4 (patch, pieces, drawing). §2 `solar` and `panels` → Task 1; placement and the sun rule → Task 2. §3 chimneys → Task 3. §4 rainwater goods → Task 4. §5 importer → Task 5. Testing → the tests named in each task plus `fittings_test`. Out of scope respected.
- **Placeholders.** Every step carries its code. The two places where a literal may need correcting (the solar patch's columns, the chimney's offsets, the gutter count) each name the command that settles it and say the derivation is the contract.
- **Type consistency.** `Dwelling#solar/#chimney` (Task 2) are what `roof_section` and `chimney` read (Tasks 2–3) and what `Rows#build` writes (Task 5). `RowGenerator::CHIMNEY_SIDE` (Task 3) is what the importer's width gate reads (Task 5). `fittingsFor(surface)` (Task 4) is what both `countMaterials` and `buildFittings` call. `capReadout`'s new fields (`gutters`, `downpipes`, `fittingPools`, `shownFittings`) are what `fittings_test` asserts, and its existing fields are what `gables_test` still asserts.
