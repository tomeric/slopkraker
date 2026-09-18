# Geleen Two Islands Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A fifth world, `geleen`, of two islands of real 3DBAG buildings on real AHN terrain — the Dassenkuillaan estate and the Sint-Marcellinus church — generated as terrace rows with per-dwelling collapse, joined by the real roads, imported reproducibly into checked-in fixtures.

**Architecture:** Ruby gains a `row` recipe kind whose generator builds attached dwellings and boxes in a row-aligned frame from the existing wall/roof/interior/rubble modules and rotates the result; every surface carries a bay, and the collapse rule runs per bay with party walls shared. An importer under `Game::Import` reads PostGIS and the AHN grid read-only and writes fixture files beside the hand-made ones. The client learns three small things: bays in collapses and state, road ribbons draped on the terrain, and a `?spawn=` parameter.

**Tech Stack:** Rails 8.1 (plain Ruby under `app/models/game/`), SQLite, three.js 0.170 (vendored), Rapier wasm 0.20, Minitest, Capybara + headless Chrome; PostGIS 3.6 through `psql` (read-only) and a raw Float32 AHN grid, both only at import time.

**Spec:** `docs/superpowers/specs/2026-09-18-geleen-two-islands-design.md`

## Global Constraints

- Every tuning number lives in Ruby and ships in the spec; the JS holds no constants of its own beyond defaults mirroring Ruby's.
- **The `building` recipe path is untouched.** `test/models/game/building/generator_test.rb` and `test/models/world_summary_test.rb` must stay green after every task; the four worlds' `piece_count`s are the proof.
- **Piece index space is never culled, only geometry is**, and **generation order is the contract**: the row generator's order is pinned by a worked example.
- **Rubble is appended last**, whatever the recipe kind.
- **The sibling database is strictly read-only**: every query runs with `PGOPTIONS="-c default_transaction_read_only=on"`. Nothing in the app talks to it at runtime.
- **Health and mass are computed by one method on both sides** (`Material#health_for`, `#mass_for`), never derived from rounded spec geometry.
- Never create or remove a Rapier body inside a drain callback; nothing here does.
- Any system test that breaks something passes `visit_world(..., match: "its-own-name")`.
- The dev server is never killed for a test run. Run one test file between steps; the full system suite runs once at the end of Task 12.
- `node` is at `~/.local/share/mise/installs/node/22.23.2/bin/node`; use it for `node --check` on every JS file touched.
- Commit straight to `main`; end commit messages with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Baseline: `bin/rails test` is **353 runs, 0 failures**. It must stay at 0 failures after every task.

## File Structure

| file | responsibility |
|---|---|
| `app/models/game/damage/match_state.rb` | applies a batch; now also says whether it was truncated |
| `app/channels/arena_channel.rb` | replies `error: batch_truncated` |
| `app/javascript/game/net/damage_reporter.js` | splits a batch to the cap |
| `app/models/game/material.rb` | `health_for`/`mass_for` round once |
| `app/models/game/building/surface.rb` | `bay`, `between`, `bays`, `rotated`, rounded spec geometry |
| `app/models/game/building/surface_set.rb` | `bays`, `for_bay` |
| `app/models/game/damage/collapse.rb` | one `Run` per bay, shared walls at half weight |
| `app/models/game/damage/object_state.rb` | `collapsed` map, per-bay settle and reveal |
| `app/models/game/building/rubble.rb` | `pile_indices`/`revealed_count` take a bay |
| `db/migrate/…_collapse_per_bay.rb` | `object_damages.collapsed` JSON replaces `collapsed_from` |
| `app/models/game/building/row.rb` | the `row` recipe: fields and validation |
| `app/models/game/building/row_generator.rb` | dwellings, party walls, roof sections, boxes, pyramid, rubble with bays, rotation |
| `app/models/game/building/generator.rb` | dispatches on `kind` |
| `app/models/game/building/openings.rb` | no door on a face under three columns |
| `app/javascript/game/world/{building,buildings,rubble,falling_pieces}.js`, `engine.js` | bays on the client |
| `db/migrate/…_add_roads_to_worlds.rb`, `app/models/world.rb`, `app/models/game/scene.rb` | roads polylines in the scene |
| `app/javascript/game/render/roads_view.js` | one ribbon mesh |
| `app/javascript/controllers/arena_controller.js`, `engine.js` | `?spawn=` |
| `app/models/game/import/{dem,classifier,rows,tiles,fixtures}.rb` | the importer's stages, POROs |
| `lib/tasks/geleen.rake`, `lib/import/geleen/*.sql` | `bin/rails geleen:import` |
| `test/fixtures/{worlds,world_objects,terrain_tiles}/geleen.yml` | the generated world |
| `test/fixtures/files/geleen/` | the importer's own test inputs |

---

### Task 1: Damage batches are never silently truncated

**Files:**
- Modify: `app/models/game/damage/match_state.rb:28-53`
- Modify: `app/channels/arena_channel.rb:36-49`
- Modify: `app/models/game/spec.rb` (the `damage:` rules block)
- Modify: `app/javascript/game/net/damage_reporter.js`
- Modify: `app/javascript/game/engine.js:121` (reporter construction) and `:388` (`case "error"`)
- Test: `test/models/game/damage/match_state_test.rb`, `test/models/game/arena_channel_test.rb`, `test/models/game/spec_test.rb`, `test/system/damage_batching_test.rb`

**Interfaces:**
- Produces: `MatchState#apply_batch(hits)` → `{ "broken", "collapses", "truncated" => Boolean }`; `Spec.default_rules[:damage][:max_hits_per_batch]` = `MatchState::MAX_HITS_PER_BATCH`; `DamageReporter.new({ connection, hz, maxHits })`; `window.__arenaNetErrors()` → array of error reasons received.

- [ ] **Step 1: Failing tests (Ruby)**

In `test/models/game/damage/match_state_test.rb`, replace the body of `"an over-long batch is truncated"`:

```ruby
  test "an over-long batch is truncated, and says so" do
    hits = Array.new(Game::Damage::MatchState::MAX_HITS_PER_BATCH + 1) { |i| [ @house.id, i, 500.0, "impact" ] }
    result = @state.apply_batch(hits)

    assert_equal Game::Damage::MatchState::MAX_HITS_PER_BATCH, result["broken"].length
    assert result["truncated"], "a dropped hit has to be reported, never swallowed"
    assert_equal false, @state.apply_batch([ [ @house.id, 1000, 500.0, "impact" ] ])["truncated"]
  end
```

In `test/models/game/arena_channel_test.rb` add:

```ruby
  test "a batch over the cap is applied to the cap and answered with an error" do
    subscribe(match: "capped", world: "targets")
    hits = Array.new(Game::Damage::MatchState::MAX_HITS_PER_BATCH + 1) { |i| [ house.id, i, 500.0, "impact" ] }

    perform :damage, "seq" => 1, "hits" => hits

    error = transmissions.find { |t| t["type"] == "error" }
    assert error, "the sender was not told"
    assert_equal "batch_truncated", error["reason"]
    assert_equal Game::Damage::MatchState::MAX_HITS_PER_BATCH, error["kept"]
  end
```

In `test/models/game/spec_test.rb` add:

```ruby
  test "the client is told how many hits a batch may carry" do
    assert_equal Game::Damage::MatchState::MAX_HITS_PER_BATCH,
                 Game::Spec.default_rules.dig(:damage, :max_hits_per_batch)
  end
```

- [ ] **Step 2: Run them, expect failures**

Run: `bin/rails test test/models/game/damage/match_state_test.rb test/models/game/arena_channel_test.rb test/models/game/spec_test.rb`
Expected: 3 failures (`truncated` nil, no error transmission, nil rule).

- [ ] **Step 3: Server side**

`match_state.rb`, in `apply_batch`:

```ruby
      def apply_batch(hits)
        broken = []
        touched = {}
        all = Array(hits)
        # The cap bounds a bad client; it must never be silent. What is dropped is reported
        # back so the sender knows its view and the server's have parted.
        truncated = all.length > MAX_HITS_PER_BATCH

        all.first(MAX_HITS_PER_BATCH).each do |hit|
          # … unchanged body …
        end

        collapses = touched.filter_map do |object_id, state|
          storey = state.settle
          storey && [ object_id, storey ]
        end

        { "broken" => broken, "collapses" => collapses, "truncated" => truncated }
      end
```

`arena_channel.rb`, in `damage` after the checkout:

```ruby
    transmit({ type: "error", reason: "batch_truncated", kept: Game::Damage::MatchState::MAX_HITS_PER_BATCH }) if result["truncated"]
    return if result["broken"].empty? && result["collapses"].empty?
```

`spec.rb`, in `damage:` after `spread: 0.45,`:

```ruby
          # How many hits one message may carry. The server keeps the first this many and
          # answers with an error for the rest, so the client splits its batches here and a
          # frame that breaks a thousand cells still reaches the server whole.
          max_hits_per_batch: Damage::MatchState::MAX_HITS_PER_BATCH
```

- [ ] **Step 4: Ruby tests pass**

Run the three files. Expected: all pass.

- [ ] **Step 5: Client splits, and records errors**

`damage_reporter.js`:

```js
export class DamageReporter {
  constructor({ connection, hz = 20, maxHits = 512 }) {
    this.connection = connection
    this.interval = 1 / hz
    this.maxHits = maxHits
    this.elapsed = 0
    this.queue = []
    this.seq = 0
    this.sent = 0
  }

  // … report() unchanged …

  update(dt) {
    this.elapsed += dt
    if (this.elapsed < this.interval) return
    this.elapsed = 0
    if (this.queue.length === 0) return

    const hits = this.queue
    this.queue = []
    // In messages of at most the server's cap, which it shipped: a frame that broke a
    // thousand cells is three messages rather than one that loses two thirds of itself.
    for (let start = 0; start < hits.length; start += this.maxHits) {
      const chunk = hits.slice(start, start + this.maxHits)
      if (this.connection?.sendDamage({ seq: ++this.seq, hits: chunk })) this.sent += chunk.length
    }
  }
}
```

`engine.js:121`: `this.reporter = new DamageReporter({ connection: this.connection, hz: this.spec.rules.snapshot_hz, maxHits: this.spec.rules.damage.max_hits_per_batch })` (keep whatever the existing arguments are, add `maxHits`). At `case "error":` push the reason: `this.netErrors.push(data.reason)` with `this.netErrors = []` in the constructor beside `collapsesSeen`, and beside `__arenaCollapses`: `window.__arenaNetErrors = () => this.netErrors.slice()`.

Run: `node --check` on both files.

- [ ] **Step 6: System test**

`test/system/damage_batching_test.rb`:

```ruby
require "application_system_test_case"

# A frame that breaks more cells than one message may carry must still reach the server
# whole. Measured before this: a church's ground storey knocked out in one frame arrived as
# exactly 512 broken pieces, and the collapse the client was owed never came.
class DamageBatchingTest < ApplicationSystemTestCase
  test "a thousand breaks in one frame all reach the server" do
    visit_world("targets", match: "damage-batching")
    wait_for(message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }

    id = page.evaluate_script("window.__arenaBuildingIds()[0]")
    broke = page.evaluate_script(<<~JS, id)
      (() => {
        const id = arguments[0]
        const spec = window.__arenaBuildingSpec(id)
        const before = window.__arenaBuildingStanding(id)
        for (const s of spec.surfaces.filter(s => s.kind === "floor" || s.kind === "roof")) {
          for (let i = s.off; i < s.off + s.cols * s.rows; i++) window.__arenaDamagePiece(i, 5000, id)
        }
        return before - window.__arenaBuildingStanding(id)
      })()
    JS
    assert_operator broke, :>, Game::Damage::MatchState::MAX_HITS_PER_BATCH, "not enough broke for the cap to matter"

    match = Match.find_by!(key: "damage-batching")
    wait_for(timeout: 15, message: "the server never caught up") do
      Game::Damage::Registry.checkout(match) { |state| state.state_for([ id ]).first["broken_count"] } == broke
    end
    assert_empty page.evaluate_script("window.__arenaNetErrors()"), "the client should never be told it was truncated"
  end
end
```

- [ ] **Step 7: Run it**

Run: `bin/rails test test/system/damage_batching_test.rb`
Expected: PASS. Then `bin/rails test` → 0 failures.

- [ ] **Step 8: Commit**

```bash
git add app/models/game/damage/match_state.rb app/channels/arena_channel.rb app/models/game/spec.rb app/javascript/game/net/damage_reporter.js app/javascript/game/engine.js test/models/game/damage/match_state_test.rb test/models/game/arena_channel_test.rb test/models/game/spec_test.rb test/system/damage_batching_test.rb
git commit -m "Split damage batches to the cap and never truncate one in silence"
```

---

### Task 2: Health rounds once; spec geometry rounds

**Files:**
- Modify: `app/models/game/material.rb` (`health_for`, `mass_for`)
- Modify: `app/models/game/building/surface.rb` (`to_spec`)
- Test: `test/models/game/materials_test.rb`, create `test/models/game/building/surface_test.rb`
- Modify: `docs/superpowers/specs/2026-09-18-geleen-two-islands-design.md` (Testing bullet about parity)

**Interfaces:**
- Produces: `Material#health_for(area, thickness)` and `#mass_for` return values rounded to 3 decimals; `Surface#to_spec` vectors rounded to 5 decimals, `w`/`h`/`t` to 3.

- [ ] **Step 1: Failing tests**

`materials_test.rb`:

```ruby
  # Health is computed on both sides of the wire -- shipped to the client, recomputed by
  # the server -- so it must be the same number to the last digit on both. Rounding here,
  # in the one method both call, is what makes that true by construction.
  test "health and mass are rounded where both sides compute them" do
    brick = Game::Materials.fetch(:brick)

    assert_equal brick.health_for(0.87, 0.3).round(3), brick.health_for(0.87, 0.3)
    assert_equal brick.mass_for(0.87, 0.3).round(3), brick.mass_for(0.87, 0.3)
    assert_in_delta 3.754, brick.health_for(0.87, 0.3), 1e-9
  end
```

`test/models/game/building/surface_test.rb`:

```ruby
require "test_helper"

class Game::Building::SurfaceTest < ActiveSupport::TestCase
  def wall(**overrides)
    Game::Building::Surface.new(**{
      kind: :wall, storey: 0, material: Game::Materials.fetch(:brick),
      origin: Game::Vector3.new(0.1234567, 0, 0.7654321),
      u: Game::Vector3.new(0.7219454902358199, 0, -0.6919499325299205), v: Game::Vector3.new(0, 1, 0),
      width: 5.5700001, height: 2.8650001, cols: 6, rows: 3, thickness: 0.3, seed: 3
    }.merge(overrides))
  end

  test "the spec carries geometry rounded to what a metre needs" do
    spec = wall.to_spec

    assert_equal [ 0.12346, 0.0, 0.76543 ], spec[:o]
    assert_equal [ 0.72195, 0.0, -0.69195 ], spec[:u]
    assert_equal 5.57, spec[:w]
    assert_equal 2.865, spec[:h]
  end

  test "the health in the spec is exactly what the server will compute" do
    surface = wall
    brick = Game::Materials.fetch(:brick)

    assert_equal brick.health_for(surface.cell_area, surface.thickness), surface.to_spec[:hp]["brick"]
  end
end
```

- [ ] **Step 2: Run, expect failures**

Run: `bin/rails test test/models/game/materials_test.rb test/models/game/building/surface_test.rb`
Expected: rounding assertions fail.

- [ ] **Step 3: Implement**

`material.rb`:

```ruby
    # Rounded HERE and nowhere else. This number is shipped to the client in the spec and
    # recomputed by the server when a hit lands, and the two have to be identical to the
    # last digit or a client breaks a piece the server still holds standing. Three
    # decimals is a thousandth of a hit point.
    def health_for(area, thickness)
      (health_per_m2 * area * thickness_factor(thickness)).round(3)
    end

    def mass_for(area, thickness)
      (density * area * thickness).round(3)
    end
```

`surface.rb` `to_spec`: `o: origin.to_a.map { |f| f.round(5) }`, likewise `u`, `v`, `n`; `w: width.round(3)`, `h: height.round(3)`, `t: thickness.round(3)`, with the comment: `# Geometry only. Nothing on the client derives health or mass from these; hp and kg ship precomputed by the one method the server also calls.`

- [ ] **Step 4: Tests pass, nothing else moved**

Run: `bin/rails test`. Expected: 0 failures (the rubble depth test uses volumes, not health; if any assertion compares an exact unrounded health, update it to call `health_for`). Run `bin/rails test test/system/parity_test.rb` — still green: the parity pairs do not compute health.

- [ ] **Step 5: Fix the spec's sentence**

In the design doc §5, replace "and the `damage` parity case is extended with `health_for` over every material × cell size × thickness" with "and `surface_test` asserts the spec's `hp` equals `health_for` exactly; the client never computes health, so there is no JS side to hold to parity".

- [ ] **Step 6: Commit**

```bash
git add app/models/game/material.rb app/models/game/building/surface.rb test/models/game/materials_test.rb test/models/game/building/surface_test.rb docs/superpowers/specs/2026-09-18-geleen-two-islands-design.md
git commit -m "Round health once where both sides compute it, and round spec geometry"
```

---

### Task 3: Surfaces carry a bay and can be rotated

**Files:**
- Modify: `app/models/game/building/surface.rb`
- Modify: `app/models/game/building/surface_set.rb`
- Test: `test/models/game/building/surface_test.rb`, `test/models/game/building/generator_test.rb` (one assertion)

**Interfaces:**
- Produces: `Surface.new(..., bay: 0, between: nil, bays: nil)`; readers `bay`, `between`, `bays`; `Surface#shared?` (`between` present); `Surface#rotated(yaw)`; spec keys `bay` (only when non-zero), `between` (only when present), `bays` (only when present); `SurfaceSet#bays` → sorted array of bay ids over non-rubble surfaces; `SurfaceSet#for_bay(bay)` → `{ own: [surfaces], shared: [surfaces] }`.

- [ ] **Step 1: Failing tests** (`surface_test.rb`)

```ruby
  test "a surface belongs to bay 0 unless told otherwise, and says nothing about it" do
    assert_equal 0, wall.bay
    assert_nil wall.between
    assert_not wall.to_spec.key?(:bay)
    assert_not wall.to_spec.key?(:between)
  end

  test "a bay and a shared wall ride into the spec" do
    assert_equal 2, wall(bay: 2).to_spec[:bay]
    party = wall(between: [ 1, 2 ])
    assert party.shared?
    assert_equal [ 1, 2 ], party.to_spec[:between]
  end

  test "per-cell bays ride into the spec and survive an offset" do
    surface = wall(bays: [ 0 ] * 9 + [ 1 ] * 9).with_offset(40)

    assert_equal [ 0 ] * 9 + [ 1 ] * 9, surface.to_spec[:bays]
    assert_equal 40, surface.piece_offset
  end

  # The whole of what rotation is allowed to touch: origin, u, v, and therefore n. Every
  # index, every cell's material and every count is exactly as it was.
  test "rotating a surface turns its frame and nothing else" do
    surface = wall(origin: Game::Vector3.new(2, 0, 0), u: Game::Vector3.new(1, 0, 0), bay: 1).with_offset(7)
    turned = surface.rotated(Math::PI / 2)

    assert_in_delta 0.0, turned.origin.x, 1e-9
    assert_in_delta 2.0, turned.origin.z, 1e-9
    assert_in_delta 0.0, turned.u.x, 1e-9
    assert_in_delta 1.0, turned.u.z, 1e-9
    assert_equal surface.v, turned.v
    assert_equal [ surface.cols, surface.rows, surface.piece_offset, surface.bay ], [ turned.cols, turned.rows, turned.piece_offset, turned.bay ]
    assert_equal surface.patches, turned.patches
    assert_same surface, surface.rotated(0.0)
  end
```

And in `generator_test.rb`:

```ruby
  test "a single house is one bay with nothing shared" do
    set = house

    assert_equal [ 0 ], set.bays
    assert_empty set.for_bay(0)[:shared]
    assert_equal set.surfaces.reject { |s| s.kind == :rubble }.length, set.for_bay(0)[:own].length
  end
```

- [ ] **Step 2: Run, expect failures** (unknown keyword `bay`).

- [ ] **Step 3: Implement**

`surface.rb`: add `attr_reader :bay, :between, :bays`; constructor keywords `bay: 0, between: nil, bays: nil`; `@bay = bay.to_i; @between = between&.map(&:to_i); @bays = bays`; pass all three through `with_offset`; add:

```ruby
      # A party wall: supports the bays on both sides of it and is felled by neither.
      def shared? = !between.nil?

      # The same surface turned about the world's y axis, which is how a building generated
      # in its own frame is put down at its real bearing. Origin, u and v turn; every count,
      # index, patch and material is untouched, because a rotation is a picture and the
      # indices are the contract.
      def rotated(yaw)
        return self if yaw.zero?

        c = Math.cos(yaw)
        s = Math.sin(yaw)
        turn = ->(vec) { Vector3.new(vec.x * c - vec.z * s, vec.y, vec.x * s + vec.z * c) }
        self.class.new(
          kind: kind, storey: storey, material: material, origin: turn.call(origin), u: turn.call(u), v: turn.call(v),
          width: width, height: height, cols: cols, rows: rows, thickness: thickness,
          patches: patches, piece_offset: piece_offset, seed: seed, mix: mix, bay: bay, between: between, bays: bays
        )
      end
```

In `to_spec`'s `tap`: `spec[:bay] = bay unless bay.zero?`; `spec[:between] = between if between`; `spec[:bays] = bays if bays`.

`surface_set.rb`:

```ruby
      # Every bay in the building: the part of it that stands or falls together. A single
      # house is one bay; a terrace is one per dwelling; a church one per part. Rubble is
      # left out -- it belongs to no bay's structure -- and a shared wall belongs to both
      # of its neighbours.
      def bays
        surfaces.reject { |s| s.kind == :rubble }.flat_map { |s| s.between || [ s.bay ] }.uniq.sort
      end

      # What the collapse rule weighs for one bay: its own surfaces, and the shared walls
      # it leans on.
      def for_bay(bay)
        {
          own: surfaces.select { |s| s.kind != :rubble && !s.shared? && s.bay == bay },
          shared: surfaces.select { |s| s.shared? && s.between.include?(bay) }
        }
      end
```

- [ ] **Step 4: Tests pass**: `bin/rails test test/models/game/building/` then `bin/rails test`. The four worlds' specs gain no key (bay 0 omitted).

- [ ] **Step 5: Commit**

```bash
git add app/models/game/building/surface.rb app/models/game/building/surface_set.rb test/models/game/building/surface_test.rb test/models/game/building/generator_test.rb
git commit -m "Give every surface a bay, let party walls be shared, and let a surface be rotated"
```

---

### Task 4: The collapse rule runs per bay

**Files:**
- Modify: `app/models/game/damage/collapse.rb`
- Test: `test/models/game/damage/collapse_test.rb`

**Interfaces:**
- Consumes: `SurfaceSet#bays`, `#for_bay`, `Surface#shared?` (Task 3).
- Produces: `Collapse.evaluate(surfaces:, broken:, rules:, health: {}, collapsed: {})` → `Result(collapsed: Hash{bay => storey}, broken: Array, health: Hash)`. `collapsed` is the input map with every bay that failed added or lowered; a bay that did not move keeps its entry. `Collapse::SHARED_WEIGHT = 0.5`.

- [ ] **Step 1: Adapt the existing tests to the map**

In `collapse_test.rb`, every `collapsed_from: N` keyword becomes `collapsed: { 0 => N }`; every `result.collapsed_from` becomes `result.collapsed[0]`; `assert_nil result.collapsed_from` becomes `assert_empty result.collapsed`. Then add a two-bay set and its tests:

```ruby
  # Two dwellings of 6 x 9 m sharing a party wall, one storey of 3 m, 1 m cells, no
  # openings, built by hand so the arithmetic can be followed: each bay owns a front and a
  # back wall of 18 cells; the party wall is 27 cells and is half of each bay's support.
  def pair
    brick = Game::Materials.fetch(:brick)
    east, south, up = Game::Vector3.new(1, 0, 0), Game::Vector3.new(0, 0, 1), Game::Vector3.new(0, 1, 0)
    wall = lambda do |x0, z0, x1, z1, bay: 0, between: nil|
      along = Game::Vector3.new(x1 - x0, 0, z1 - z0)
      Game::Building::Surface.new(
        kind: :wall, storey: 0, material: brick, origin: Game::Vector3.new(x0, 0, z0), u: along.normalised, v: up,
        width: along.length, height: 3.0, cols: along.length.round, rows: 3, thickness: 0.3, bay: bay, between: between
      )
    end
    roof = lambda do |x0, bay|
      Game::Building::Surface.new(
        kind: :roof, storey: 1, material: Game::Materials.fetch(:roof_tile), origin: Game::Vector3.new(x0, 3.0, 0),
        u: east, v: south, width: 6.0, height: 9.0, cols: 6, rows: 9, thickness: 0.2, bay: bay
      )
    end
    Game::Building::SurfaceSet.new([
      wall.call(0, 0, 6, 0, bay: 0), wall.call(6, 9, 0, 9, bay: 0),
      wall.call(6, 0, 12, 0, bay: 1), wall.call(12, 9, 6, 9, bay: 1),
      wall.call(6, 0, 6, 9, between: [ 0, 1 ]),
      roof.call(0, 0), roof.call(6, 1)
    ], storey_count: 1)
  end

  def bay_walls(set, bay) = set.for_bay(bay)[:own].select { |s| s.kind == :wall }
  def party(set) = set.surfaces.find(&:shared?)

  test "a pair is two bays sharing one wall" do
    assert_equal [ 0, 1 ], pair.bays
    assert_equal [ party(pair).piece_offset ], pair.for_bay(1)[:shared].map(&:piece_offset)
  end

  test "taking the front and back out of one dwelling drops that dwelling and no other" do
    set = pair
    result = evaluate(set, broken: indices_of(bay_walls(set, 1)))

    assert_equal({ 1 => 0 }, result.collapsed)
    assert_includes result.broken, set.for_bay(1)[:own].find { |s| s.kind == :roof }.piece_offset, "the bay's own roof comes down"
    assert_not_includes result.broken, party(set).piece_offset, "a shared wall is never felled by a bay"
    assert_empty result.broken & indices_of(set.for_bay(0)[:own]), "the neighbour is untouched"
  end

  test "the front alone is not enough" do
    set = pair
    result = evaluate(set, broken: indices_of(bay_walls(set, 1).first))

    assert_empty result.collapsed
  end

  # A party wall is half of each neighbour's support: losing it hurts both, and finishing
  # either one then takes only its front.
  test "a party wall gone weakens both neighbours" do
    set = pair
    assert_empty evaluate(set, broken: indices_of(party(set))).collapsed
    both = indices_of(party(set)) + indices_of(bay_walls(set, 0).first) + indices_of(bay_walls(set, 1).first)

    assert_equal({ 0 => 0, 1 => 0 }, evaluate(set, broken: both).collapsed)
  end

  test "a bay that has already fallen is not reported again and never rises" do
    set = pair
    result = evaluate(set, broken: indices_of(bay_walls(set, 1)), collapsed: { 1 => 0 })

    assert_equal({ 1 => 0 }, result.collapsed)
    assert_empty result.broken
  end
```

- [ ] **Step 2: Run, expect failures** (`collapsed` keyword unknown; `Result#collapsed` missing).

- [ ] **Step 3: Implement**

Rewrite the module's public face and make `Run` bay-aware:

```ruby
    module Collapse
      LOAD_BEARING = %i[wall partition].freeze
      # What a shared wall is worth to each of the bays leaning on it. Counted in full a
      # mid-terrace dwelling keeps 70% of its support with its front and back gone and never
      # falls; at half it comes down, an end dwelling needs its partition as well, and a
      # party wall taken out condemns both neighbours.
      SHARED_WEIGHT = 0.5

      Result = Struct.new(:collapsed, :broken, :health, keyword_init: true)

      # `collapsed` is the map of bay => storey it has already come down from. Every bay is
      # weighed; the bays that fail fell their own surfaces, never a shared one, so no bay's
      # fall changes a neighbour's support and a row does not domino.
      def self.evaluate(surfaces:, broken:, rules:, health: {}, collapsed: {})
        gone = Set.new(broken)
        left = health.dup
        felled = []
        result = collapsed.to_h { |bay, storey| [ bay.to_i, storey.to_i ] }

        surfaces.bays.each do |bay|
          run = Run.new(surfaces, rules, bay: bay, gone: gone, health: left, felled: felled)
          storey = run.evaluate(collapsed_from: result[bay])
          result[bay] = storey unless storey.nil?
        end

        Result.new(collapsed: result, broken: felled.sort, health: left)
      end

      class Run
        def initialize(surfaces, rules, bay:, gone:, health:, felled:)
          @rules = rules
          @bay = bay
          parts = surfaces.for_bay(bay)
          @own = parts[:own]
          @shared = parts[:shared]
          @storey_count = surfaces.storey_count
          @gone = gone
          @health = health
          @felled = felled
        end

        # The storey this bay has come down to after this evaluation, or nil if it moved
        # nowhere. Shares `gone`, `health` and `felled` with every other bay's run, because
        # a shared wall broken by a hit is gone for both of its neighbours.
        def evaluate(collapsed_from:)
          @collapsed_from = collapsed_from
          before = collapsed_from
          cascade
          @collapsed_from == before ? nil : @collapsed_from
        end

        private
          attr_reader :rules

          # … cascade, fails?, capacity_fraction, load_fraction, intact_capacity, intact_load,
          #   mass_above, fell_from, pancake, load_bearing_cells, remaining, standing?, break!
          #   are unchanged except where shown below …

          def lowest_failing
            ceiling = @collapsed_from || @storey_count
            (0...ceiling).find { |storey| fails?(storey) }
          end

          # The bay's own load-bearing area in full, plus half of every wall it shares.
          def structural_area(storey, &standing)
            own = @own.select { |s| s.storey == storey && LOAD_BEARING.include?(s.kind) }.sum { |s| s.structural_area(&standing) }
            shared = @shared.select { |s| s.storey == storey }.sum { |s| s.structural_area(&standing) }
            own + shared * SHARED_WEIGHT
          end

          # Own surfaces only. A shared wall carries itself, and is never felled from here.
          def each_cell(from: nil, only: nil)
            @own.each do |surface|
              next if surface.kind == :rubble
              next if from && surface.storey < from
              next if only && surface.storey != only

              surface.rows.times do |row|
                surface.cols.times do |col|
                  yield surface, row, col, surface.piece_index(row, col)
                end
              end
            end
          end
      end
    end
```

Every `surfaces.for_storey(storey)` in the old `structural_area` is replaced by the version above; `mass_above`, `fell_from`, `pancake` and `load_bearing_cells` already go through `each_cell` and need no change. Keep every existing comment that still applies.

- [ ] **Step 4: Tests pass**: `bin/rails test test/models/game/damage/collapse_test.rb`, then `bin/rails test` — `ObjectState#settle` still passes `collapsed_from:` and reads `.collapsed_from`, so it breaks here: change it minimally in this task to `collapsed: { 0 => @collapsed_from }.compact` and `result.collapsed[0]`; Task 7 replaces it properly.

- [ ] **Step 5: Commit**

```bash
git add app/models/game/damage/collapse.rb app/models/game/damage/object_state.rb test/models/game/damage/collapse_test.rb
git commit -m "Evaluate collapse per bay, with party walls shared at half weight and never felled"
```

---

### Task 5: The `row` recipe and its generator, dwellings only

**Files:**
- Create: `app/models/game/building/row.rb`
- Create: `app/models/game/building/row_generator.rb`
- Modify: `app/models/game/building/generator.rb` (dispatch on kind)
- Test: `test/models/game/building/row_test.rb`

**Interfaces:**
- Produces: `Game::Building::Row.from(hash)` with readers `yaw, cell, seed, band (z0, z1), storeys, storey_height, eaves, ridge, roof, dwellings ([{x0:, x1:}]), boxes ([Box]), footprint, category, pands`; raises `Row::Invalid`. `Game::Building::RowGenerator.call(row)` → `SurfaceSet`. `Generator.call(recipe)` dispatches: `recipe["kind"] == "row"` → `RowGenerator`, else the existing path.
- The worked example (`test/models/game/building/row_test.rb#pair`) is the contract: two dwellings `x 0..6, 6..12`, band `[0, 9]`, 2 storeys of 3.0 m, eaves 6.0, ridge 8.5, gable, cell 1.0, seed 1, yaw 0, no boxes, footprint the 12 × 9 rectangle → **29 surfaces, 840 pieces**, offsets `[0, 18, 36, 54, 72, 90, 108, 126, 144, 171, 198, 225, 252, 279, 306, 360, 414, 432, 450, 504, 558, 576, 594, 624, 654, 681, 711, 741, 768]`, kinds `wall×14, floor, floor, partition, partition, floor, floor, partition, partition, roof, roof, gable, roof, roof, gable, rubble`.

- [ ] **Step 1: The failing worked example**

```ruby
require "test_helper"

class Game::Building::RowTest < ActiveSupport::TestCase
  # Two dwellings of 6 x 9 m, two storeys of 3 m, one gable, 1 m cells, no boxes. Chosen so
  # every count can be worked by hand: a 6 m wall is 6 x 3 = 18 cells, a 9 m one 27, a deck
  # 54, a partition across the 6 m width 18, a roof section 6.4 x 5.15 -> 6 x 5 = 30, a
  # gable end 9 x 3 = 27, and the rubble grid ceil(18/2) x ceil(15/2) = 9 x 8 = 72.
  def pair(**overrides)
    Game::Building::Generator.call({
      "kind" => "row", "category" => "house", "pands" => %w[000001 000002],
      "yaw" => 0.0, "cell" => 1.0, "seed" => 1,
      "band" => [ 0.0, 9.0 ], "storeys" => 2, "storey_height" => 3.0, "eaves" => 6.0, "ridge" => 8.5, "roof" => "gable",
      "dwellings" => [ { "x0" => 0.0, "x1" => 6.0 }, { "x0" => 6.0, "x1" => 12.0 } ],
      "boxes" => [],
      "footprint" => [ [ 0, 0 ], [ 12, 0 ], [ 12, 9 ], [ 0, 9 ] ]
    }.merge(overrides))
  end

  # THE CONTRACT. Offsets are handed out in this order; change the order and damage
  # recorded against one wall comes back on another.
  test "the worked example generates exactly what it is supposed to" do
    set = pair

    assert_equal 29, set.surfaces.length
    assert_equal 840, set.piece_count
    assert_equal 2, set.storey_count
    assert_equal %i[wall] * 14 + %i[floor floor partition partition floor floor partition partition
                                    roof roof gable roof roof gable rubble],
                 set.surfaces.map(&:kind)
    assert_equal [ 0, 18, 36, 54, 72, 90, 108, 126, 144, 171, 198, 225, 252, 279,
                   306, 360, 414, 432, 450, 504, 558, 576, 594, 624, 654, 681, 711, 741, 768 ],
                 set.surfaces.map(&:piece_offset)
  end

  test "every surface knows its bay, and the party wall is shared" do
    set = pair
    walls = set.surfaces.select { |s| s.kind == :wall }

    assert_equal [ 0 ] * 4 + [ 1 ] * 4, walls.first(8).map(&:bay), "front and back walls per dwelling"
    assert_equal [ 1, 1, 0, 0 ], walls[8, 4].map(&:bay), "the right end belongs to the last dwelling, the left to the first"
    assert_equal [ [ 0, 1 ], [ 0, 1 ] ], walls[12, 2].map(&:between), "party walls, one per storey"
    assert_equal [ 0, 1 ], set.bays
    assert_equal [ 0, 0, 0, 1, 1, 1 ], set.surfaces.select { |s| %i[roof gable].include?(s.kind) }.map(&:bay)
  end

  test "rubble is last and carries a bay per cell" do
    rubble = pair.surfaces.last

    assert_equal :rubble, rubble.kind
    assert_equal rubble.cols * rubble.rows, rubble.bays.length
    assert_equal [ 0, 1 ], rubble.bays.uniq.sort
    assert_equal 0, rubble.bays[rubble.cols / 4], "a heap on the left half belongs to the first dwelling"
    assert_equal 1, rubble.bays[rubble.cols - 1 - rubble.cols / 4], "and one on the right to the second"
  end

  test "every dwelling gets a front door at ground level and the party wall gets nothing" do
    set = pair
    walls = set.surfaces.select { |s| s.kind == :wall }
    fronts = [ walls[0], walls[4] ]
    fronts.each { |front| assert front.patches.any? { |p| p.material == :timber }, "no door" }
    assert_empty walls[12].patches
  end

  test "the roof is one continuous ridge cut at the party line" do
    planes = pair.surfaces.select { |s| s.kind == :roof }

    assert_equal 4, planes.length
    assert_equal [ 6, 6, 6, 6 ], planes.map(&:cols), "each section spans its dwelling plus the end overhang"
    assert_in_delta planes[0].origin.y, planes[2].origin.y, 1e-9, "the same eaves"
    assert_equal planes[0].v, planes[2].v, "the same pitch"
  end

  test "every cell round trips through its index" do
    set = pair
    set.surfaces.each do |surface|
      surface.rows.times do |row|
        surface.cols.times do |col|
          found, r, c = set.at(surface.piece_index(row, col))
          assert_equal [ surface.piece_offset, row, col ], [ found.piece_offset, r, c ]
        end
      end
    end
  end

  # Rotation is a picture, the indices are the contract.
  test "a rotated row has the same pieces at turned positions" do
    flat = pair
    turned = pair("yaw" => Math::PI / 2)

    assert_equal flat.piece_count, turned.piece_count
    assert_equal flat.surfaces.map(&:piece_offset), turned.surfaces.map(&:piece_offset)
    flat.surfaces.zip(turned.surfaces).each do |a, b|
      assert_equal a.rows.times.map { |r| a.cols.times.map { |c| a.material_at(r, c).name } },
                   b.rows.times.map { |r| b.cols.times.map { |c| b.material_at(r, c).name } }
    end
    front = turned.surfaces.first
    assert_in_delta 0.0, front.u.x, 1e-9
    assert_in_delta 1.0, front.u.z, 1e-9
  end

  test "a flat roof is one deck per dwelling" do
    set = pair("roof" => "flat", "ridge" => 6.0)

    assert_equal 2, set.surfaces.count { |s| s.kind == :roof }
    assert_empty set.surfaces.select { |s| s.kind == :gable }
  end

  test "the building kind still goes the old way" do
    house = Game::Building::Generator.call(
      footprint: [ [ 0, 0 ], [ 12, 0 ], [ 12, 15 ], [ 0, 15 ] ],
      storeys: 3, storey_height: 3.0, eaves: 9.0, ridge: 12.75, roof: "gable", cell: 1.0, seed: 7
    )
    assert_equal 1553, house.piece_count
  end

  test "a row is validated" do
    assert_raises(Game::Building::Row::Invalid) { pair("dwellings" => [ { "x0" => 6.0, "x1" => 0.0 } ]) }
    assert_raises(Game::Building::Row::Invalid) { pair("band" => [ 9.0, 0.0 ]) }
    assert_raises(Game::Building::Row::Invalid) { pair("roof" => "thatch") }
  end
end
```

- [ ] **Step 2: Run, expect failures** (`Row` undefined).

- [ ] **Step 3: The recipe** — `app/models/game/building/row.rb`:

```ruby
module Game
  module Building
    # A row of attached dwellings and the boxes beside them, in the row's own frame: x
    # along the row, z across it, the street at z = 0, every coordinate positive, and `yaw`
    # turning local into world about the object's position. A single house is a row of
    # one; a shed cluster or a church is a row of no dwellings and several boxes.
    class Row
      ROOFS = %w[gable flat].freeze
      BOX_ROOFS = %w[gable flat pyramid].freeze

      class Invalid < StandardError; end

      Dwelling = Struct.new(:x0, :x1, keyword_init: true) do
        def width = x1 - x0
      end

      # A one-or-more-storey ring with its own heights and roof: an annex, a shed, a garage,
      # a part of a church. `bay` says which dwelling it stands or falls with, or which bay
      # of its own it is; it is written by the importer and never guessed here.
      Box = Struct.new(:ring, :eaves, :ridge, :storeys, :roof, :door, :solid, :bay, :name, keyword_init: true) do
        def storey_height = eaves / storeys
        def bounds
          xs = ring.map(&:first)
          zs = ring.map(&:last)
          [ xs.min, zs.min, xs.max, zs.max ]
        end
      end

      attr_reader :yaw, :cell, :seed, :band, :storeys, :storey_height, :eaves, :ridge, :roof,
                  :dwellings, :boxes, :footprint, :category, :pands

      def self.from(attributes)
        a = attributes.to_h.transform_keys(&:to_s)
        new(
          yaw: a.fetch("yaw", 0.0).to_f, cell: a.fetch("cell", 1.0).to_f, seed: a.fetch("seed", 0).to_i,
          band: Array(a.fetch("band", [ 0.0, 0.0 ])).map(&:to_f),
          storeys: a.fetch("storeys", 1).to_i, storey_height: a.fetch("storey_height", 2.8).to_f,
          eaves: a.fetch("eaves", 2.8).to_f, ridge: a.fetch("ridge", a.fetch("eaves", 2.8)).to_f,
          roof: a.fetch("roof", "flat").to_s,
          dwellings: Array(a["dwellings"]).map { |d| d = d.transform_keys(&:to_s); Dwelling.new(x0: d.fetch("x0").to_f, x1: d.fetch("x1").to_f) },
          boxes: Array(a["boxes"]).map.with_index { |b, i| box_from(b, i) },
          footprint: Array(a.fetch("footprint")).map { |x, z| [ x.to_f, z.to_f ] },
          category: a.fetch("category", "building").to_s, pands: Array(a["pands"]).map(&:to_s)
        )
      end

      def self.box_from(hash, index)
        b = hash.transform_keys(&:to_s)
        eaves = b.fetch("eaves", b["height"]).to_f
        Box.new(
          ring: Array(b.fetch("ring")).map { |x, z| [ x.to_f, z.to_f ] }, eaves: eaves,
          ridge: b.fetch("ridge", eaves).to_f, storeys: b.fetch("storeys", 1).to_i, roof: b.fetch("roof", "flat").to_s,
          door: b.fetch("door", false), solid: b.fetch("solid", false), bay: b["bay"]&.to_i, name: b.fetch("name", "box-#{index}").to_s
        )
      end

      def initialize(yaw:, cell:, seed:, band:, storeys:, storey_height:, eaves:, ridge:, roof:, dwellings:, boxes:, footprint:, category:, pands:)
        @yaw, @cell, @seed, @band, @storeys, @storey_height = yaw, cell, seed, band, storeys, storey_height
        @eaves, @ridge, @roof, @dwellings, @boxes, @footprint, @category, @pands = eaves, ridge, roof, dwellings, boxes, footprint, category, pands
        validate!
      end

      def x0 = dwellings.first.x0
      def x1 = dwellings.last.x1
      def z0 = band[0]
      def z1 = band[1]
      def depth = z1 - z0
      def rise = [ ridge - eaves, 0.0 ].max
      # The row's rectangle in its own frame, or nil for a row of boxes only.
      def rect = dwellings.any? ? [ x0, z0, x1, z1 ] : nil
      def party_lines = dwellings.each_cons(2).map { |a, b| (a.x1 + b.x0) / 2.0 }

      private
        def validate!
          raise Invalid, "a footprint needs at least three points" if footprint.length < 3
          raise Invalid, "cell size must be positive" unless cell.positive?
          raise Invalid, "roof must be one of #{ROOFS.join(", ")}" unless ROOFS.include?(roof)
          raise Invalid, "the ridge cannot sit below the eaves" if ridge < eaves
          raise Invalid, "the band must run front to back" if dwellings.any? && z1 <= z0
          raise Invalid, "storeys must be positive" unless storeys.positive?
          dwellings.each { |d| raise Invalid, "a dwelling must have width" unless d.x1 > d.x0 }
          dwellings.each_cons(2) { |a, b| raise Invalid, "dwellings must run left to right" if b.x0 < a.x1 - 0.5 }
          boxes.each do |box|
            raise Invalid, "a box needs a ring" if box.ring.length < 3
            raise Invalid, "a box roof must be one of #{BOX_ROOFS.join(", ")}" unless BOX_ROOFS.include?(box.roof)
            raise Invalid, "a box needs a bay" if box.bay.nil?
            raise Invalid, "a box must have storeys" unless box.storeys.positive?
          end
        end
    end
  end
end
```

- [ ] **Step 4: The generator (dwellings; boxes come in Task 6)** — `app/models/game/building/row_generator.rb`:

```ruby
module Game
  module Building
    # A Row in, a SurfaceSet out. Built in the row's frame from the same modules a single
    # house is built from, then every surface is turned by the row's yaw.
    #
    # THE ORDER BELOW IS THE CONTRACT, exactly as it is in Generator: offsets are handed
    # out by walking the surfaces in sequence, so a reordering renumbers every piece after
    # it and damage recorded against one wall comes back applied to another. The worked
    # example in row_test pins it.
    module RowGenerator
      UP = Vector3.new(0, 1, 0)
      EAST = Vector3.new(1, 0, 0)
      SOUTH = Vector3.new(0, 0, 1)
      # Only the row's ends get one; a section in the middle meets its neighbour flush.
      OVERHANG = Roof::OVERHANG

      def self.call(row)
        row = Row.from(row) unless row.is_a?(Row)
        built = dwellings(row) + boxes(row)
        surfaces = built + rubble(row, built)
        SurfaceSet.new(surfaces.map { |s| s.rotated(row.yaw) }, storey_count: row.storeys)
      end

      # 1 fronts and backs, 2 ends, 3 party walls, 4 interiors, 5 roof sections.
      def self.dwellings(row)
        return [] if row.dwellings.empty?

        n = row.dwellings.length
        built = []
        row.dwellings.each_with_index do |d, i|
          openings = Openings.new(seed: row.seed + i)
          row.storeys.times { |s| built << wall(row, [ d.x0, row.z0 ], [ d.x1, row.z0 ], storey: s, openings: openings, edge: 0, bay: i) }
          row.storeys.times { |s| built << wall(row, [ d.x1, row.z1 ], [ d.x0, row.z1 ], storey: s, openings: openings, edge: 2, bay: i) }
        end
        row.storeys.times { |s| built << wall(row, [ row.x1, row.z0 ], [ row.x1, row.z1 ], storey: s, openings: Openings.new(seed: row.seed + 7), edge: 1, bay: n - 1) }
        row.storeys.times { |s| built << wall(row, [ row.x0, row.z1 ], [ row.x0, row.z0 ], storey: s, openings: Openings.new(seed: row.seed + 11), edge: 3, bay: 0) }
        row.party_lines.each_with_index do |x, i|
          row.storeys.times { |s| built << wall(row, [ x, row.z0 ], [ x, row.z1 ], storey: s, openings: nil, edge: 5, between: [ i, i + 1 ]) }
        end
        row.dwellings.each_with_index { |d, i| built.concat Interior.build(rectangle(row, d.x0, d.x1)).map { |s| tagged(s, i) } }
        row.dwellings.each_with_index { |d, i| built.concat roof_section(row, d, i) }
        built
      end

      def self.wall(row, from, to, storey:, openings:, edge:, bay: 0, between: nil, storeys: row.storeys, storey_height: row.storey_height, seed: row.seed)
        along = Vector3.new(to[0] - from[0], 0.0, to[1] - from[1])
        cols = Walls.cells(along.length, row.cell)
        rows = Walls.cells(storey_height, row.cell)
        Surface.new(
          kind: :wall, storey: storey, material: Materials.fetch(:brick),
          origin: Vector3.new(from[0], storey * storey_height, from[1]), u: along.normalised, v: UP,
          width: along.length, height: storey_height, cols: cols, rows: rows, thickness: Walls::THICKNESS,
          patches: openings ? openings.for_wall(edge: edge, storey: storey, cols: cols, rows: rows) : [],
          seed: seed, bay: bay, between: between
        )
      end

      # A single-house Recipe over a rectangle of the row, so Interior and Roof can be
      # reused exactly as they are.
      def self.rectangle(row, x0, x1, z0: row.z0, z1: row.z1, storeys: row.storeys, storey_height: row.storey_height, eaves: row.eaves, ridge: row.ridge, roof: row.roof)
        Recipe.from(
          footprint: [ [ x0, z0 ], [ x1, z0 ], [ x1, z1 ], [ x0, z1 ] ],
          storeys: storeys, storey_height: storey_height, eaves: eaves, ridge: [ ridge, eaves ].max,
          roof: roof == "pyramid" ? "flat" : roof, cell: row.cell, seed: row.seed
        )
      end

      def self.tagged(surface, bay)
        Surface.new(
          kind: surface.kind, storey: surface.storey, material: surface.material, origin: surface.origin, u: surface.u, v: surface.v,
          width: surface.width, height: surface.height, cols: surface.cols, rows: surface.rows, thickness: surface.thickness,
          patches: surface.patches, seed: surface.seed, mix: surface.mix, bay: bay
        )
      end

      # This dwelling's share of one roof: two planes cut at the party lines, the ridge
      # along the row, an overhang only at the row's ends, and a gable end on the first
      # and the last dwelling. Flat: one deck per dwelling.
      def self.roof_section(row, d, i)
        return [ tagged(Roof.flat(rectangle(row, d.x0, d.x1)), i) ] if row.roof == "flat"

        first = i.zero?
        last = i == row.dwellings.length - 1
        run = row.depth / 2.0
        slope = Math.hypot(run, row.rise)
        start = d.x0 - (first ? OVERHANG : 0.0)
        span = d.width + (first ? OVERHANG : 0.0) + (last ? OVERHANG : 0.0)
        planes = [ 1, -1 ].map do |side|
          origin = Vector3.new(start, row.eaves, side.positive? ? row.z0 : row.z1)
          up_slope = Vector3.new(0.0, row.rise, side * run)
          Surface.new(
            kind: :roof, storey: row.storeys, material: Materials.fetch(:roof_tile),
            origin: origin, u: EAST, v: up_slope.normalised, width: span, height: slope,
            cols: Walls.cells(span, row.cell), rows: Walls.cells(slope, row.cell), thickness: Roof::THICKNESS, bay: i
          )
        end
        ends = []
        ends << gable_end(row, d.x0, i) if first
        ends << gable_end(row, d.x1, i) if last
        planes + ends
      end

      def self.gable_end(row, x, bay)
        cols = Walls.cells(row.depth, row.cell)
        rows = [ Walls.cells(row.rise, row.cell), 1 ].max
        Surface.new(
          kind: :gable, storey: row.storeys, material: Materials.fetch(:brick),
          origin: Vector3.new(x, row.eaves, row.z0), u: SOUTH, v: UP, width: row.depth, height: row.rise,
          cols: cols, rows: rows, thickness: Roof::GABLE_THICKNESS, patches: Roof.clip(cols, rows), seed: row.seed, bay: bay
        )
      end

      def self.boxes(row) = []   # Task 6

      # LAST. Over the union footprint, and each heap tagged with the dwelling whose
      # x-interval its centre falls in -- or, in a row of boxes, the nearest box's bay.
      def self.rubble(row, built)
        surface = Rubble.build(rectangle_for_footprint(row), built).first
        bays = surface.rows.times.flat_map do |r|
          surface.cols.times.map do |c|
            x = surface.origin.x + (c + 0.5) * surface.cell_width
            z = surface.origin.z + (r + 0.5) * surface.cell_height
            bay_at(row, x, z)
          end
        end
        [ Surface.new(
          kind: :rubble, storey: -1, material: surface.material, origin: surface.origin, u: surface.u, v: surface.v,
          width: surface.width, height: surface.height, cols: surface.cols, rows: surface.rows, thickness: surface.thickness,
          patches: surface.patches, seed: surface.seed, mix: surface.mix, bays: bays
        ) ]
      end

      def self.rectangle_for_footprint(row)
        Recipe.from(footprint: row.footprint, storeys: [ row.storeys, 1 ].max, storey_height: row.storey_height,
                    eaves: row.eaves, ridge: [ row.ridge, row.eaves ].max, roof: "flat", cell: row.cell, seed: row.seed)
      end

      def self.bay_at(row, x, z)
        if row.dwellings.any?
          lines = row.party_lines
          lines.index { |line| x < line } || row.dwellings.length - 1
        else
          nearest = row.boxes.each_with_index.min_by { |box, _| bx0, bz0, bx1, bz1 = box.bounds; Math.hypot(((bx0 + bx1) / 2.0) - x, ((bz0 + bz1) / 2.0) - z) }
          nearest ? nearest.first.bay : 0
        end
      end
    end
  end
end
```

`Roof.flat` currently returns a Surface via `[...].first`; it is public and reused here. `generator.rb`:

```ruby
      def self.call(recipe)
        return RowGenerator.call(recipe) if recipe.is_a?(Row) || recipe.to_h.transform_keys(&:to_s)["kind"] == "row"
        # … existing body unchanged …
```

- [ ] **Step 5: Run the row test until the worked example passes**

Run: `bin/rails test test/models/game/building/row_test.rb`. If a count differs from the plan, work out which side is wrong by hand from the comment on `pair` before touching either — the numbers in Step 1 were derived from the sizes in that comment. Then `bin/rails test` → 0 failures.

- [ ] **Step 6: Commit**

```bash
git add app/models/game/building/row.rb app/models/game/building/row_generator.rb app/models/game/building/generator.rb test/models/game/building/row_test.rb
git commit -m "Add the row recipe: attached dwellings generated as one building in their own frame"
```

---

### Task 6: Boxes, the pyramid roof, and the two-column door rule

**Files:**
- Modify: `app/models/game/building/row_generator.rb` (`boxes`)
- Modify: `app/models/game/building/openings.rb:39-47`
- Test: `test/models/game/building/row_test.rb`, `test/models/game/building/generator_test.rb`

**Interfaces:**
- Consumes: `Row::Box` (Task 5).
- Produces: `RowGenerator.boxes(row)` → surfaces in recipe order: kept walls per storey, a deck per storey, the roof (`flat` deck | `Roof.gable` | `pyramid` four planes); `RowGenerator.clip(ring, axis, at, side)` (Sutherland–Hodgman against one half-plane, used by the importer in Task 11); `Openings#for_wall` gives no door when `cols < DOOR_WIDTH`.

- [ ] **Step 1: Failing tests** (`row_test.rb`)

```ruby
  # A rear extension against the second dwelling: 3 x 6 m, one storey of 2.8 m, flat.
  def annex(**overrides)
    { "ring" => [ [ 6.0, 9.0 ], [ 9.0, 9.0 ], [ 9.0, 15.0 ], [ 6.0, 15.0 ] ], "eaves" => 2.8, "ridge" => 2.8,
      "storeys" => 1, "roof" => "flat", "door" => false, "solid" => false, "bay" => 1, "name" => "annex" }.merge(overrides)
  end

  test "a box against the row generates no wall where it stands against it" do
    set = pair("boxes" => [ annex ])
    box_walls = set.surfaces.select { |s| s.kind == :wall && s.height == 2.8 }

    assert_equal 3, box_walls.length, "four edges, one of them along the row's back wall"
    assert box_walls.none? { |w| w.origin.z == 9.0 && w.u.z.zero? }, "the junction edge was generated"
    assert_equal [ 1 ] * 3, box_walls.map(&:bay)
  end

  test "a box's decks are void where they would lie inside the row" do
    set = pair("boxes" => [ annex("ring" => [ [ 6.0, 7.0 ], [ 9.0, 7.0 ], [ 9.0, 15.0 ], [ 6.0, 15.0 ] ]) ])
    deck = set.surfaces.select { |s| s.kind == :floor && s.bay == 1 }.last

    assert_equal :void, deck.material_at(0, 0).name, "the two metres inside the row"
    assert_equal :concrete, deck.material_at(deck.rows - 1, 0).name
  end

  test "two boxes that meet share one wall" do
    twin = annex("ring" => [ [ 9.0, 9.0 ], [ 12.0, 9.0 ], [ 12.0, 15.0 ], [ 9.0, 15.0 ] ], "name" => "twin")
    set = pair("boxes" => [ annex, twin ])
    box_walls = set.surfaces.select { |s| s.kind == :wall && s.height == 2.8 }

    assert_equal 5, box_walls.length, "3 + 3 minus the wall they share"
  end

  test "a row of boxes only is legal, and every box is its own bay" do
    shed = { "ring" => [ [ 0, 0 ], [ 2.2, 0 ], [ 2.2, 3.2 ], [ 0, 3.2 ] ], "eaves" => 2.5, "ridge" => 2.5, "storeys" => 1, "roof" => "flat", "solid" => true, "bay" => 0 }
    twin = shed.merge("ring" => [ [ 2.2, 0 ], [ 4.4, 0 ], [ 4.4, 3.2 ], [ 2.2, 3.2 ] ], "bay" => 1)
    set = pair("dwellings" => [], "boxes" => [ shed, twin ], "footprint" => [ [ 0, 0 ], [ 4.4, 0 ], [ 4.4, 3.2 ], [ 0, 3.2 ] ], "storeys" => 1)

    assert_equal [ 0, 1 ], set.bays
    assert set.surfaces.select { |s| s.kind == :wall }.all? { |w| w.patches.empty? }, "a solid box has no openings"
    assert_equal :rubble, set.surfaces.last.kind
  end

  test "a pyramid roof is four triangles meeting at one apex" do
    tower = { "ring" => [ [ 0, 0 ], [ 8, 0 ], [ 8, 8 ], [ 0, 8 ] ], "eaves" => 24.0, "ridge" => 30.0, "storeys" => 6, "roof" => "pyramid", "bay" => 0 }
    set = pair("dwellings" => [], "boxes" => [ tower ], "footprint" => tower["ring"], "storeys" => 6)
    planes = set.surfaces.select { |s| s.kind == :roof }

    assert_equal 4, planes.length
    planes.each do |plane|
      assert_in_delta 24.0, plane.origin.y, 1e-9
      assert plane.patches.any? { |p| p.material == :void }, "the corners above the pitch should be void"
      assert_equal :roof_tile, plane.material_at(plane.rows - 1, plane.cols / 2).name, "the apex column stays"
    end
  end

  test "a gable box roofs over its own box" do
    chapel = { "ring" => [ [ 0, 0 ], [ 6, 0 ], [ 6, 10 ], [ 0, 10 ] ], "eaves" => 4.0, "ridge" => 7.0, "storeys" => 1, "roof" => "gable", "bay" => 0 }
    set = pair("dwellings" => [], "boxes" => [ chapel ], "footprint" => chapel["ring"], "storeys" => 1)

    assert_equal 2, set.surfaces.count { |s| s.kind == :roof }
    assert_equal 2, set.surfaces.count { |s| s.kind == :gable }
  end

  test "a door face under three columns gets no door" do
    shed = { "ring" => [ [ 0, 0 ], [ 2.2, 0 ], [ 2.2, 3.2 ], [ 0, 3.2 ] ], "eaves" => 2.5, "ridge" => 2.5, "storeys" => 1, "roof" => "flat", "door" => true, "bay" => 0 }
    set = pair("dwellings" => [], "boxes" => [ shed ], "footprint" => shed["ring"], "storeys" => 1)
    front = set.surfaces.find { |s| s.kind == :wall }

    assert_equal 2, front.cols
    assert front.patches.none? { |p| %i[timber steel].include?(p.material) }, "a two-cell face was all door and lintel"
  end
```

In `generator_test.rb`:

```ruby
  test "a wall too narrow for a door gets none rather than being all door" do
    narrow = Game::Building::Openings.new(seed: 1).for_wall(edge: 0, storey: 0, cols: 2, rows: 3)
    assert narrow.none? { |p| p.material == :timber }
  end
```

- [ ] **Step 2: Run, expect failures.**

- [ ] **Step 3: Implement the boxes**

Replace `def self.boxes(row) = []` with:

```ruby
      TOLERANCE = 0.5
      COINCIDENT = 0.4

      # 6. Boxes: annexes, sheds, garages, the parts of a church. Each wall is generated
      # once -- never where a box stands against the row, never inside a bigger box that
      # came before it, never twice where two boxes meet.
      def self.boxes(row)
        kept = []
        containers = []
        built = []
        row.boxes.each_with_index do |box, i|
          openings = box.solid ? nil : Openings.new(seed: row.seed + 100 + i)
          edges(box.ring).each_with_index do |(from, to), e|
            next if row.rect && on_or_inside?(from, row.rect) && on_or_inside?(to, row.rect)
            next if containers.any? { |ring| inside_ring?(from, ring) && inside_ring?(to, ring) }
            next if kept.any? { |k| coincident?(k, [ from, to ]) }

            kept << [ from, to ]
            box.storeys.times do |s|
              built << wall(row, from, to, storey: s, openings: openings, edge: box.door && e.zero? ? 0 : 1 + e,
                            bay: box.bay, storeys: box.storeys, storey_height: box.storey_height, seed: row.seed + 100 + i)
            end
          end
          box.storeys.times do |s|
            built << clipped_deck(box.ring, row.rect, containers, y: s * box.storey_height, cell: row.cell, kind: :floor,
                                  material: s.zero? ? :concrete : :timber, storey: s, thickness: Interior::DECK_THICKNESS, bay: box.bay)
          end
          built.concat box_roof(row, box, containers)
          containers << box.ring
        end
        built
      end

      def self.box_roof(row, box, containers)
        case box.roof
        when "gable"
          x0, z0, x1, z1 = box.bounds
          Roof.gable(rectangle(row, x0, x1, z0: z0, z1: z1, storeys: box.storeys, storey_height: box.storey_height,
                               eaves: box.eaves, ridge: box.ridge, roof: "gable")).map { |s| tagged(s, box.bay) }
        when "pyramid" then pyramid(box, row.cell)
        else
          [ clipped_deck(box.ring, row.rect, containers, y: box.eaves, cell: row.cell, kind: :roof, material: :concrete,
                         storey: box.storeys, thickness: Roof::THICKNESS, bay: box.bay) ]
        end
      end

      # A horizontal grid over the ring's box, void wherever a cell's centre falls outside
      # the ring or inside the row or an earlier box -- geometry culled, index space kept.
      # Void cells are merged into runs, one patch per run.
      def self.clipped_deck(ring, rect, containers, y:, cell:, kind:, material:, storey:, thickness:, bay:)
        xs = ring.map(&:first)
        zs = ring.map(&:last)
        x0, x1, z0, z1 = xs.min, xs.max, zs.min, zs.max
        cols = Walls.cells(x1 - x0, cell)
        rows = Walls.cells(z1 - z0, cell)
        cw = (x1 - x0) / cols
        ch = (z1 - z0) / rows
        patches = rows.times.flat_map do |r|
          void = cols.times.reject do |c|
            cx = x0 + (c + 0.5) * cw
            cz = z0 + (r + 0.5) * ch
            Rubble.contains?(ring, cx, cz) && !(rect && strictly_inside?([ cx, cz ], rect)) &&
              containers.none? { |other| Rubble.contains?(other, cx, cz) }
          end
          void.slice_when { |a, b| b != a + 1 }.map { |run| Surface::Patch.new(col0: run.first, row0: r, col1: run.last, row1: r, material: :void) }
        end
        Surface.new(kind: kind, storey: storey, material: Materials.fetch(material), origin: Vector3.new(x0, y, z0), u: EAST, v: SOUTH,
                    width: x1 - x0, height: z1 - z0, cols: cols, rows: rows, thickness: thickness, patches: patches, bay: bay)
      end

      # Four triangular planes from the eaves of the ring's box to one apex. Each is a
      # rectangle clipped to its triangle with void, exactly as a gable end is: Roof.clip
      # already draws that triangle.
      def self.pyramid(box, cell)
        x0, z0, x1, z1 = box.bounds
        cx = (x0 + x1) / 2.0
        cz = (z0 + z1) / 2.0
        rise = [ box.ridge - box.eaves, 0.5 ].max
        corners = [ [ x0, z0 ], [ x1, z0 ], [ x1, z1 ], [ x0, z1 ] ]
        corners.each_with_index.map do |from, i|
          to = corners[(i + 1) % 4]
          along = Vector3.new(to[0] - from[0], 0.0, to[1] - from[1])
          mid = [ (from[0] + to[0]) / 2.0, (from[1] + to[1]) / 2.0 ]
          inward = Vector3.new(cx - mid[0], rise, cz - mid[1])
          cols = Walls.cells(along.length, cell)
          rows = [ Walls.cells(inward.length, cell), 1 ].max
          Surface.new(kind: :roof, storey: box.storeys, material: Materials.fetch(:roof_tile),
                      origin: Vector3.new(from[0], box.eaves, from[1]), u: along.normalised, v: inward.normalised,
                      width: along.length, height: inward.length, cols: cols, rows: rows, thickness: Roof::THICKNESS,
                      patches: Roof.clip(cols, rows), bay: box.bay)
        end
      end

      def self.edges(ring) = ring.each_with_index.map { |p, i| [ p, ring[(i + 1) % ring.length] ] }

      def self.on_or_inside?(p, rect, tol = TOLERANCE)
        x0, z0, x1, z1 = rect
        p[0] >= x0 - tol && p[0] <= x1 + tol && p[1] >= z0 - tol && p[1] <= z1 + tol
      end

      def self.strictly_inside?(p, rect, tol = 0.05)
        x0, z0, x1, z1 = rect
        p[0] > x0 + tol && p[0] < x1 - tol && p[1] > z0 + tol && p[1] < z1 - tol
      end

      def self.inside_ring?(p, ring, tol = TOLERANCE)
        Rubble.contains?(ring, p[0], p[1]) || Rubble.distance_to_ring(ring, p[0], p[1]) <= tol
      end

      # Two segments along one line, overlapping: the second is a wall that already exists.
      def self.coincident?(a, b, tol = COINCIDENT)
        (a0, a1), (b0, b1) = a, b
        dx, dz = a1[0] - a0[0], a1[1] - a0[1]
        length = Math.hypot(dx, dz)
        return false if length < 1e-6

        dir = [ dx / length, dz / length ]
        [ b0, b1 ].each do |p|
          off = (p[0] - a0[0]) * -dir[1] + (p[1] - a0[1]) * dir[0]
          return false if off.abs > tol
        end
        t0 = (b0[0] - a0[0]) * dir[0] + (b0[1] - a0[1]) * dir[1]
        t1 = (b1[0] - a0[0]) * dir[0] + (b1[1] - a0[1]) * dir[1]
        [ t0, t1 ].max > tol && [ t0, t1 ].min < length - tol
      end

      # Sutherland-Hodgman against one half-plane: the part of `ring` where coordinate
      # `axis` (0 for x, 1 for z) is >= `at` (side +1) or <= `at` (side -1). The importer
      # uses it to split a dwelling that reaches past the band.
      def self.clip(ring, axis, at, side)
        out = []
        ring.each_with_index do |p, i|
          q = ring[(i + 1) % ring.length]
          pin = (p[axis] - at) * side >= 0
          qin = (q[axis] - at) * side >= 0
          out << p if pin
          next unless pin != qin

          t = (at - p[axis]) / (q[axis] - p[axis])
          out << [ p[0] + t * (q[0] - p[0]), p[1] + t * (q[1] - p[1]) ]
        end
        out
      end
```

`Rubble.contains?` and `Rubble.distance_to_ring` are already public module methods. `openings.rb`, in `for_wall`: `doorway = door(cols, rows) if edge == DOOR_EDGE && storey == DOOR_STOREY && cols >= DOOR_WIDTH`, with the comment: `# A face narrower than the door gets none: at one metre cells a two-cell shed front was all door under a full-width lintel.`

- [ ] **Step 4: Run** `bin/rails test test/models/game/building/` then `bin/rails test`. Expected: 0 failures (the street's narrowest wall is seven columns wide, so no fixture loses its door; `world_summary_test` will say so if one did).

- [ ] **Step 5: Commit**

```bash
git add app/models/game/building/row_generator.rb app/models/game/building/openings.rb test/models/game/building/row_test.rb test/models/game/building/generator_test.rb
git commit -m "Give rows their boxes: annexes, sheds and church parts with flat, gable and pyramid roofs"
```

---

### Task 7: Per-bay collapse on the server: state, rubble reveal, persistence

**Files:**
- Modify: `app/models/game/damage/object_state.rb`
- Modify: `app/models/game/damage/match_state.rb` (`apply_batch` collapses, `state_for`, `flush!`, `build_state`)
- Modify: `app/models/game/building/rubble.rb` (`revealed_count`, `pile_indices`)
- Create: `db/migrate/20260918120000_collapse_per_bay.rb`
- Test: `test/models/game/damage/object_state_test.rb`, `test/models/game/damage/match_state_test.rb`, `test/models/game/building/rubble_test.rb`

**Interfaces:**
- Produces: `ObjectState.new(..., collapsed: {})`, `#collapsed` → `Hash{Integer bay => Integer storey}`, `#settle` → `Array[[bay, storey]]` of bays that moved (empty when nothing did); `apply_batch` collapses as `[object_id, storey, bay]`; `state_for` entries carry `"collapsed" => { "0" => 1 }`; `Rubble.pile_indices(surface, bay: nil)`, `Rubble.revealed_count(surface, storey_count:, collapsed_from:, bay: nil)`; `object_damages.collapsed` JSON.

- [ ] **Step 1: Failing tests**

`rubble_test.rb`:

```ruby
  # Two dwellings' worth of heaps tagged by bay. Each bay's order runs outward from the
  # middle of ITS heaps, quantised and index-tied as before.
  def two_bay_rubble
    Game::Building::Generator.call(
      "kind" => "row", "yaw" => 0.0, "cell" => 1.0, "seed" => 1, "band" => [ 0.0, 9.0 ], "storeys" => 2,
      "storey_height" => 3.0, "eaves" => 6.0, "ridge" => 8.5, "roof" => "gable",
      "dwellings" => [ { "x0" => 0.0, "x1" => 6.0 }, { "x0" => 6.0, "x1" => 12.0 } ], "boxes" => [],
      "footprint" => [ [ 0, 0 ], [ 12, 0 ], [ 12, 9 ], [ 0, 9 ] ]
    ).surfaces.last
  end

  test "pile indices can be asked for one bay, and the bays partition the heaps" do
    surface = two_bay_rubble
    all = Game::Building::Rubble.pile_indices(surface)
    left = Game::Building::Rubble.pile_indices(surface, bay: 0)
    right = Game::Building::Rubble.pile_indices(surface, bay: 1)

    assert_equal all.sort, (left + right).sort
    assert_empty left & right
    assert left.all? { |i| surface.bays[surface.local_index(i)].zero? }
  end

  test "a bay's first heap is the one nearest the middle of that bay" do
    surface = two_bay_rubble
    first = Game::Building::Rubble.pile_indices(surface, bay: 0).first
    col = surface.local_index(first) % surface.cols

    assert_operator col, :<, surface.cols / 2, "the first heap of the left bay is on the left"
  end

  test "revealed_count for a bay counts that bay's heaps only" do
    surface = two_bay_rubble
    count = Game::Building::Rubble.revealed_count(surface, storey_count: 2, collapsed_from: 0, bay: 1)

    assert_equal Game::Building::Rubble.pile_indices(surface, bay: 1).length, count
  end

  test "without bays the order is what it always was" do
    surface = surface()
    assert_equal Game::Building::Rubble.pile_indices(surface), Game::Building::Rubble.pile_indices(surface, bay: nil)
  end
```

`object_state_test.rb` (add):

```ruby
  test "settle reports the bays that moved and keeps them" do
    state = Game::Damage::ObjectState.new(surfaces: @set, piece_count: @set.piece_count, rules: Game::Spec.default_rules)
    walls = @set.for_storey(0).select { |s| s.kind == :wall }.first(2)
    walls.each { |w| (w.piece_offset...(w.piece_offset + w.piece_count)).each { |i| state.apply(i, 5000.0, "impact") } }

    assert_equal [ [ 0, 0 ] ], state.settle
    assert_equal({ 0 => 0 }, state.collapsed)
    assert_empty state.settle, "a bay that has already fallen is not reported twice"
  end
```

`match_state_test.rb`: `"taking out two walls reports the collapse"` expects `[[ @house.id, 0, 0 ]]`; `"state_for hands back what a joining client needs"` asserts `assert_equal({ "0" => 0 }, entry["collapsed"])` after a collapse and `assert_equal({}, entry["collapsed"])` before; and add:

```ruby
  test "a collapse survives a restart as a map per bay" do
    @state.apply_batch(wall_hits(2))
    @state.flush!
    row = ObjectDamage.find_by!(match: @match, world_object_id: @house.id)
    assert_equal({ "0" => 0 }, row.collapsed)

    fresh = Game::Damage::MatchState.new(@match, rules: Game::Spec.default_rules)
    fresh.rehydrate!
    assert_equal({ "0" => 0 }, fresh.state_for([ @house.id ]).first["collapsed"])
  end
```

- [ ] **Step 2: Run, expect failures** (no `collapsed` column, wrong tuple shape).

- [ ] **Step 3: Migration**

```ruby
# A collapse used to be one storey per building. A terrace is several dwellings and a
# church several parts, each of which stands or falls on its own, so the storey a
# building has come down from is now a map per bay. The single house of the four
# hand-made worlds is bay 0.
class CollapsePerBay < ActiveRecord::Migration[8.1]
  def up
    add_column :object_damages, :collapsed, :json, null: false, default: {}
    execute "UPDATE object_damages SET collapsed = json_object('0', collapsed_from) WHERE collapsed_from IS NOT NULL"
    remove_column :object_damages, :collapsed_from
  end

  def down
    add_column :object_damages, :collapsed_from, :integer
    execute "UPDATE object_damages SET collapsed_from = json_extract(collapsed, '$.\"0\"')"
    remove_column :object_damages, :collapsed
  end
end
```

Run: `bin/rails db:migrate && RAILS_ENV=test bin/rails db:migrate` (or `bin/rails db:prepare` for test).

- [ ] **Step 4: Rubble per bay**

```ruby
      def self.revealed_count(surface, storey_count:, collapsed_from:, bay: nil)
        return 0 if collapsed_from.nil? || storey_count.to_i <= 0

        fell = storey_count - collapsed_from
        (pile_indices(surface, bay: bay).length * fell.to_f / storey_count).round
      end

      # The piles OUTWARD FROM THE MIDDLE -- of the whole grid, or of one bay's heaps when a
      # bay is asked for. Both sides compute the same list, and the server gates damage on
      # the revealed prefix, so a bay's order has to be as much a contract as a building's.
      def self.pile_indices(surface, bay: nil)
        cells = surface.rows.times.flat_map do |row|
          surface.cols.times.filter_map do |col|
            next unless surface.material_at(row, col).name == :rubble
            next if bay && surface.bays && surface.bays[row * surface.cols + col] != bay

            [ row, col ]
          end
        end
        centre = bay && surface.bays ? centroid(cells) : [ surface.rows / 2.0, surface.cols / 2.0 ]

        cells.map { |row, col| [ (radius_from(surface, row, col, centre) * 1_000_000).round, surface.piece_index(row, col) ] }
             .sort.map(&:last)
      end

      def self.centroid(cells)
        return [ 0.0, 0.0 ] if cells.empty?

        [ cells.sum { |r, _| r + 0.5 } / cells.length, cells.sum { |_, c| c + 0.5 } / cells.length ]
      end

      # Distance from `centre` (row, col, in cells) as a share of the grid's half-extent.
      # With the grid's own centre this is exactly the old `radius`.
      def self.radius_from(surface, row, col, centre)
        Math.hypot((col + 0.5 - centre[1]) / surface.cols.to_f, (row + 0.5 - centre[0]) / surface.rows.to_f)
      end
```

Keep `radius` as `radius_from(surface, row, col, [rows/2.0, cols/2.0])` for anything still calling it.

- [ ] **Step 5: ObjectState and MatchState**

`object_state.rb`: constructor keyword `collapsed: {}` (drop `collapsed_from:`), `@collapsed = (collapsed || {}).to_h { |bay, storey| [ bay.to_i, storey.to_i ] }`, `attr_reader :collapsed`;

```ruby
      # Runs the collapse rule over what is left, bay by bay. Returns the bays that came
      # down (further) as [bay, storey] pairs, or [] if nothing changed. Everything the
      # collapse destroyed is folded in here, so the caller only broadcasts the pairs.
      def settle
        result = Collapse.evaluate(
          surfaces: @surfaces, broken: @destroyed.to_a, health: @partial,
          rules: @rules.fetch(:collapse), collapsed: @collapsed
        )
        moved = result.collapsed.reject { |bay, storey| @collapsed[bay] == storey }
        return [] if moved.empty?

        result.broken.each { |index| destroy!(index) }
        @partial = result.health.except(*result.broken)
        @collapsed = result.collapsed
        @revealed_rubble = nil
        @dirty = true
        moved.to_a
      end
```

and `revealed_rubble`:

```ruby
        def revealed_rubble
          @revealed_rubble ||= begin
            surface = @surfaces.surfaces.find { |s| s.kind == :rubble }
            if surface.nil? || @collapsed.empty?
              []
            else
              @collapsed.flat_map do |bay, from|
                bay_key = surface.bays ? bay : nil
                Building::Rubble.pile_indices(surface, bay: bay_key).first(
                  Building::Rubble.revealed_count(surface, storey_count: @surfaces.storey_count, collapsed_from: from, bay: bay_key)
                )
              end
            end
          end
        end
```

`match_state.rb`: collapses `touched.flat_map { |object_id, state| state.settle.map { |bay, storey| [ object_id, storey, bay ] } }`; `state_for`: `"collapsed" => state.collapsed.transform_keys(&:to_s)`; `flush!` rows: `collapsed: state.collapsed.transform_keys(&:to_s)` instead of `collapsed_from:`; `build_state`: `collapsed: row&.collapsed`.

- [ ] **Step 6: Run** `bin/rails test test/models/game/damage test/models/game/building/rubble_test.rb`, then `bin/rails test`. Then the system tests that read collapses today — `bin/rails test test/system/collapse_test.rb test/system/rubble_test.rb` — will FAIL until Task 8 teaches the client the new shapes; run them at the end of Task 8 instead and note it in the commit.

- [ ] **Step 7: Commit**

```bash
git add db/migrate/20260918120000_collapse_per_bay.rb db/schema.rb app/models/game/damage/object_state.rb app/models/game/damage/match_state.rb app/models/game/building/rubble.rb test/models/game/damage test/models/game/building/rubble_test.rb
git commit -m "Track collapse per bay on the server: a map of bay to storey, revealed per bay, persisted as JSON"
```

---

### Task 8: Bays on the client

**Files:**
- Modify: `app/javascript/game/world/rubble.js:317-341` (`pileOrder`)
- Modify: `app/javascript/game/world/building.js:494-660` (`collapse`, `expectRubble`, `slabLanded`, `revealRubble`, new `bays` readout)
- Modify: `app/javascript/game/world/buildings.js:132-174` (`applyCollapse`, `revealedRubble`, `applyState`)
- Modify: `app/javascript/game/world/falling_pieces.js:225` (`slabLanded(entry.bay)`) and where `entry.owner` is set (`entry.bay = shape.bay ?? 0`)
- Modify: `app/javascript/game/engine.js:371-377` (`breaks`), hooks (`__arenaBays`)
- Test: `test/system/collapse_test.rb`, `test/system/rubble_test.rb` (existing, must pass again), `bin/rails test test/system/parity_test.rb`

**Interfaces:**
- Consumes: `breaks.collapses` as `[objectId, storey, bay]`; `state.objects[].collapsed` as `{ "0": 1 }`; `surface.bay`, `surface.between`, `surface.bays` in the spec.
- Produces: `pileOrder(surface, bay = null)`; `Building#collapse(bay, fromStorey, silent)`, `#expectRubble(bay, total)`, `#slabLanded(bay)`, `#revealRubble(bay, count)`, `#bays` → `{ [bay]: fromStorey }`; `Buildings#applyCollapse(objectId, storey, bay)`, `#revealedRubble(building, fromStorey, bay)`; `window.__arenaBays(id)`.

- [ ] **Step 1: `pileOrder` per bay** (`rubble.js`)

```js
// The heaps outward from the middle -- of the whole grid, or of one bay's heaps when a bay
// is asked for -- in exactly the order Building::Rubble.pile_indices returns, because the
// server gates damage on the revealed prefix. Quantised and index-tied for the same reason
// it is in Ruby.
export function pileOrder(surface, bay = null) {
  const key = bay === null || !surface.bays ? "all" : String(bay)
  let cached = ORDERS.get(surface)?.[key]
  if (cached) return cached

  const cells = []
  for (let row = 0; row < surface.rows; row += 1) {
    for (let col = 0; col < surface.cols; col += 1) {
      if (materialAt(surface, row, col) === "void") continue
      if (key !== "all" && surface.bays[row * surface.cols + col] !== bay) continue
      cells.push([ row, col ])
    }
  }
  let centreRow = surface.rows / 2
  let centreCol = surface.cols / 2
  if (key !== "all" && cells.length > 0) {
    centreRow = cells.reduce((s, [ r ]) => s + r + 0.5, 0) / cells.length
    centreCol = cells.reduce((s, [ , c ]) => s + c + 0.5, 0) / cells.length
  }
  const piles = cells.map(([ row, col ]) => [
    Math.round(Math.hypot((col + 0.5 - centreCol) / surface.cols, (row + 0.5 - centreRow) / surface.rows) * 1000000),
    surface.off + row * surface.cols + col
  ])
  piles.sort((a, b) => a[0] - b[0] || a[1] - b[1])
  cached = piles.map((pile) => pile[1])
  if (!ORDERS.has(surface)) ORDERS.set(surface, {})
  ORDERS.get(surface)[key] = cached
  return cached
}
```

- [ ] **Step 2: `Building`** (`building.js`)

`collapse(bay, fromStorey, silent = false)`: `const coming = this.spec.surfaces.filter((surface) => !surface.between && (surface.bay ?? 0) === bay && surface.storey >= fromStorey)` — a shared wall is never in `coming`. Slabs dropped here get `slab.bay = bay`. Replace the two counters with maps: `this.expectedSlabs = this.expectedSlabs || {}; this.landedSlabs = this.landedSlabs || {}; this.pendingRubble = this.pendingRubble || {}` and at the end `this.expectedSlabs[bay] = dropped; this.landedSlabs[bay] = 0`. Record `this.collapsed = this.collapsed || {}; this.collapsed[bay] = fromStorey`.

```js
  // How much wreckage THIS BAY's collapse will eventually leave, held until the slabs
  // carrying it land. A restore has no slabs to wait for and reveals at once.
  expectRubble(bay, total) {
    this.pendingRubble[bay] = total
    if (!this.expectedSlabs[bay]) return this.revealRubble(bay, total)
    return 0
  }

  slabLanded(bay = 0) {
    this.landedSlabs[bay] = (this.landedSlabs[bay] ?? 0) + 1
    if (!this.pendingRubble[bay] || !this.expectedSlabs[bay]) return 0
    const share = Math.min(1, this.landedSlabs[bay] / this.expectedSlabs[bay])
    return this.revealRubble(bay, Math.round(this.pendingRubble[bay] * share))
  }

  // The first `count` heaps of this bay in the bay's own order -- the same order and count
  // the server works out, so the two never disagree about which heaps exist.
  revealRubble(bay, count) {
    const surface = this.spec.surfaces.find((s) => s.kind === "rubble")
    if (!surface) return 0
    const order = pileOrder(surface, surface.bays ? bay : null)
    let revealed = 0
    for (let n = 0; n < order.length && n < count; n += 1) if (this.reveal(order[n])) revealed += 1
    return revealed
  }

  get bays() {
    return { ...(this.collapsed || {}) }
  }
```

- [ ] **Step 3: `Buildings`** (`buildings.js`)

```js
  applyCollapse(objectId, fromStorey, bay = 0) {
    const building = this.byId.get(objectId)
    if (!building) return 0
    const count = building.collapse(bay, fromStorey)
    building.expectRubble(bay, this.revealedRubble(building, fromStorey, bay))
    return count
  }

  // The same arithmetic the server runs in Building::Rubble.revealed_count, over the
  // bay's own heaps: a bay gutted to the ground leaves all of its wreckage, one that lost
  // only its top floor a proportional share.
  revealedRubble(building, fromStorey, bay = 0) {
    const storeys = building.spec.storeys
    if (!storeys || fromStorey === null || fromStorey === undefined) return 0
    const surface = building.spec.surfaces.find((s) => s.kind === "rubble")
    if (!surface) return 0
    const total = pileOrder(surface, surface.bays ? bay : null).length
    return Math.round(total * (storeys - fromStorey) / storeys)
  }

  applyState(objects) {
    for (const entry of objects || []) {
      const building = this.byId.get(entry.id)
      if (!building) continue
      building.applyBroken(entry.broken, true)
      for (const [ bay, storey ] of Object.entries(entry.collapsed || {})) {
        building.collapse(Number(bay), storey, true)
        building.revealRubble(Number(bay), this.revealedRubble(building, storey, Number(bay)))
      }
    }
  }
```

Import `pileOrder` from `game/world/rubble` in `buildings.js`.

- [ ] **Step 4: `falling_pieces.js` and `engine.js`**

Where the entry is filled from `shape` (`entry.owner = shape.owner ?? null`) add `entry.bay = shape.bay ?? 0`, and at landing `entry.owner?.slabLanded(entry.bay)`. In `engine.js` the `breaks` case: `for (const [ objectId, storey, bay ] of data.collapses || []) { this.buildings.applyCollapse(objectId, storey, bay ?? 0); this.collapsesSeen++ }`. Beside `__arenaBuildingStanding`: `window.__arenaBays = (id) => this.buildings?.find(id)?.bays ?? {}`.

Run: `node --check` on all four files.

- [ ] **Step 5: Prove the single-bay world still behaves**

Run: `bin/rails test test/system/collapse_test.rb test/system/rubble_test.rb test/system/street_test.rb test/system/parity_test.rb`
Expected: all green. These are the tests that watched collapses arrive, slabs land and heaps reveal on one-bay houses; passing them is the proof that bay 0 is exactly the old behaviour.

- [ ] **Step 6: Commit**

```bash
git add app/javascript/game/world/rubble.js app/javascript/game/world/building.js app/javascript/game/world/buildings.js app/javascript/game/world/falling_pieces.js app/javascript/game/engine.js
git commit -m "Teach the client bays: a collapse names the bay it fells and reveals that bay's wreckage"
```

---

### Task 9: Roads as one ribbon on the terrain, and `?spawn=`

**Files:**
- Create: `db/migrate/20260918130000_add_roads_to_worlds.rb`
- Modify: `app/models/world.rb` (`scene`), `app/models/game/scene.rb`, `app/models/game/spec.rb` (`roads:` rules)
- Create: `app/javascript/game/render/roads_view.js`
- Modify: `app/javascript/game/engine.js` (build the view after terrain; `__arenaRoadVertices`), `app/javascript/controllers/arena_controller.js` (`spawn`), `engine.js:427-440` (`spawnVehicle`)
- Test: `test/models/world_test.rb`, `test/models/game/spec_test.rb`

**Interfaces:**
- Produces: `worlds.roads` JSON (`[{ "kind", "width", "points": [[x, z], …] }]`, default `[]`); `Scene.new(..., roads: [])`, spec `arena.roads`; `rules.roads = { lift: 0.03, colours: { residential: "#2e3236", living_street: "#33373b", tertiary: "#2a2e32", secondary: "#282c30", service: "#3a3e42", cycleway: "#5a3a2e" } }`; `buildRoadsView(scene, roads, ground, rules)` → `THREE.Mesh | null`; `window.__arenaRoadVertices()`; `GameEngine` option `spawnIndex`.

- [ ] **Step 1: Failing tests**

`world_test.rb`:

```ruby
  test "a world's roads ride into its scene as polylines" do
    world = worlds(:flat)
    world.update!(roads: [ { "kind" => "residential", "width" => 5.5, "points" => [ [ 0, 0 ], [ 40, 0 ], [ 40, 30 ] ] } ])

    roads = world.scene.to_spec[:roads]
    assert_equal 1, roads.length
    assert_equal 3, roads.first["points"].length
  end

  test "a world without roads has none, rather than nil" do
    assert_equal [], worlds(:flat).scene.to_spec[:roads]
  end
```

`spec_test.rb`:

```ruby
  test "roads ship how high they float and what colour each kind is" do
    roads = Game::Spec.default_rules.fetch(:roads)
    assert_operator roads[:lift], :>, 0
    %i[residential living_street tertiary secondary service cycleway].each { |kind| assert roads[:colours][kind], kind }
  end
```

- [ ] **Step 2: Run, expect failures** (`roads` unknown attribute).

- [ ] **Step 3: Migration, model, scene, rules**

```ruby
# Roads are drawn, not simulated: polylines the client drapes on the terrain as one mesh,
# with no colliders. A world without them has an empty list, never nil.
class AddRoadsToWorlds < ActiveRecord::Migration[8.1]
  def change
    add_column :worlds, :roads, :json, null: false, default: []
  end
end
```

`world.rb` `scene`: add `roads: roads || []`. `scene.rb`: `attr_reader :roads`, keyword `roads: []`, spec `roads: roads`. `spec.rb`, after `terrain:`:

```ruby
        # Roads are ribbons draped on the terrain and nothing else: how far above the
        # ground they float so the two never fight, and what colour each OSM kind is.
        roads: {
          lift: 0.03,
          colours: { residential: "#2e3236", living_street: "#33373b", tertiary: "#2a2e32",
                     secondary: "#282c30", service: "#3a3e42", cycleway: "#5a3a2e" }
        }
```

Run: `bin/rails db:migrate && RAILS_ENV=test bin/rails db:migrate`, then the two test files → PASS.

- [ ] **Step 4: The ribbon** — `app/javascript/game/render/roads_view.js`

```js
import * as THREE from "three"

// Every road in the world as ONE mesh. A polyline becomes a ribbon half its width either
// side of the centreline with mitred joins, subdivided so no edge is longer than STEP,
// every vertex laid on the ground it crosses plus `rules.lift`. No colliders: the car
// drives on the heightfield, which the terrain model already shapes to the road.
const STEP = 5

export function buildRoadsView(scene, roads, ground, rules = {}) {
  if (!roads || roads.length === 0) return null

  const lift = rules.lift ?? 0.03
  const colours = rules.colours ?? {}
  const positions = []
  const colors = []
  const indices = []
  const colour = new THREE.Color()
  const height = ground || (() => 0)

  for (const road of roads) {
    const points = densify(road.points, STEP)
    if (points.length < 2) continue
    colour.set(colours[road.kind] ?? "#2e3236")
    const half = (road.width ?? 5.5) / 2
    const base = positions.length / 3

    for (let i = 0; i < points.length; i += 1) {
      const [ nx, nz ] = normalAt(points, i)
      for (const side of [ -1, 1 ]) {
        const x = points[i][0] + side * nx * half
        const z = points[i][1] + side * nz * half
        positions.push(x, height(x, z) + lift, z)
        colors.push(colour.r, colour.g, colour.b)
      }
      if (i > 0) {
        const a = base + (i - 1) * 2
        indices.push(a, a + 1, a + 2, a + 1, a + 3, a + 2)
      }
    }
  }

  const geometry = new THREE.BufferGeometry()
  geometry.setAttribute("position", new THREE.Float32BufferAttribute(positions, 3))
  geometry.setAttribute("color", new THREE.Float32BufferAttribute(colors, 3))
  geometry.setIndex(indices)
  geometry.computeVertexNormals()
  const mesh = new THREE.Mesh(geometry, new THREE.MeshStandardMaterial({
    vertexColors: true, roughness: 0.95, metalness: 0.02,
    // Drawn a hair in front of the terrain it lies on, whatever the depth buffer thinks.
    polygonOffset: true, polygonOffsetFactor: -1, polygonOffsetUnits: -1
  }))
  mesh.name = "roads"
  mesh.receiveShadow = true
  scene.add(mesh)
  return mesh
}

// Points no more than `step` apart, so the ribbon follows the ground between the
// polyline's own vertices rather than bridging a dip.
function densify(points, step) {
  const out = []
  for (let i = 0; i < points.length - 1; i += 1) {
    const [ x0, z0 ] = points[i]
    const [ x1, z1 ] = points[i + 1]
    const n = Math.max(1, Math.ceil(Math.hypot(x1 - x0, z1 - z0) / step))
    for (let k = 0; k < n; k += 1) out.push([ x0 + (x1 - x0) * k / n, z0 + (z1 - z0) * k / n ])
  }
  out.push(points[points.length - 1])
  return out
}

// The unit normal at a vertex: perpendicular to the average of the directions into and
// out of it, which is what makes the join at a bend a mitre rather than a gap.
function normalAt(points, i) {
  const prev = points[Math.max(i - 1, 0)]
  const next = points[Math.min(i + 1, points.length - 1)]
  let dx = next[0] - prev[0]
  let dz = next[1] - prev[1]
  const length = Math.hypot(dx, dz) || 1
  dx /= length
  dz /= length
  return [ -dz, dx ]
}
```

In `engine.js`, after the terrain view is built: `this.roadsView = buildRoadsView(this.scene, this.spec.arena.roads, this.ground, this.spec.rules.roads)`; hook `window.__arenaRoadVertices = () => this.roadsView?.geometry.attributes.position.count ?? 0`; dispose the mesh's geometry and material in `dispose()`.

- [ ] **Step 5: `?spawn=`**

`arena_controller.js`: `spawnIndex: Number(new URLSearchParams(window.location.search).get("spawn") || 0)`. `engine.js` constructor: `this.spawnIndex = spawnIndex || 0`; in `spawnVehicle`: `const spawn = this.spec.arena.spawns[this.spawnIndex] ?? this.spec.arena.spawns[0]`.

Run: `node --check` on the three JS files; `bin/rails test`; `bin/rails test test/system/boot_test.rb` (the spec shape check).

- [ ] **Step 6: Commit**

```bash
git add db/migrate/20260918130000_add_roads_to_worlds.rb db/schema.rb app/models/world.rb app/models/game/scene.rb app/models/game/spec.rb app/javascript/game/render/roads_view.js app/javascript/game/engine.js app/javascript/controllers/arena_controller.js test/models/world_test.rb test/models/game/spec_test.rb
git commit -m "Draw a world's roads as one ribbon on the terrain, and let a URL pick the spawn"
```

---

### Task 10: Importer stages that need no database: the DEM reader and the classifier

**Files:**
- Create: `app/models/game/import/dem.rb`, `app/models/game/import/classifier.rb`
- Create: `test/fixtures/files/geleen/classifier_sample.json` (300 rows cut from the spike's `hood_pand.json`)
- Test: `test/models/game/import/dem_test.rb`, `test/models/game/import/classifier_test.rb`

**Interfaces:**
- Produces: `Game::Import::Dem.new(path:, origin_x:, origin_y:, step:, cols:, rows:, nodata: -9999.0)` with `#height_at(x, y)` (RD metres → metres NAP, bilinear over the four nearest samples; raises `Dem::NoData` on a no-data sample); `Game::Import::Classifier.category(features)` → one of `:shed :house :apartments :hall :church` from a Hash with string keys `area h_max union_rect slenderness levels osm`.

- [ ] **Step 1: The sample and the failing tests**

```bash
python3 -c "
import json; rows = json.load(open('docs/superpowers/spikes/2026-09-18-dassenkuillaan/data/hood_pand.json'))
keep = [r for r in rows if r['osm'] not in (None, 'yes')][:300]
json.dump([{k: r[k] for k in ('pand','area','h_max','union_rect','slenderness','levels','osm')} for r in keep], open('test/fixtures/files/geleen/classifier_sample.json','w'))"
```

`dem_test.rb`:

```ruby
require "test_helper"

class Game::Import::DemTest < ActiveSupport::TestCase
  # A 3 x 3 grid at 10 m: origin (100, 130) is the top-left corner, rows run south, and
  # the height is 1 + x/10 + y/100 so every answer can be worked by hand.
  def dem
    @dem ||= begin
      path = Rails.root.join("tmp/dem_test.raw")
      samples = (0...3).flat_map { |row| (0...3).map { |col| 1.0 + (100 + col * 10 + 5) / 10.0 + (130 - row * 10 - 5) / 100.0 } }
      path.binwrite(samples.pack("e*"))
      Game::Import::Dem.new(path: path, origin_x: 100.0, origin_y: 130.0, step: 10.0, cols: 3, rows: 3)
    end
  end

  test "a sample centre reads back exactly" do
    assert_in_delta 1.0 + 10.5 + 1.25, dem.height_at(105.0, 125.0), 1e-6
  end

  test "between samples it interpolates" do
    assert_in_delta 1.0 + 11.0 + 1.25, dem.height_at(110.0, 125.0), 1e-6
    assert_in_delta 1.0 + 10.5 + 1.20, dem.height_at(105.0, 120.0), 1e-6
  end

  test "outside the grid it refuses rather than guessing" do
    assert_raises(Game::Import::Dem::NoData) { dem.height_at(50.0, 125.0) }
  end
end
```

`classifier_test.rb`:

```ruby
require "test_helper"

class Game::Import::ClassifierTest < ActiveSupport::TestCase
  AGREES = { shed: %w[shed garage garages roof service static_caravan], house: %w[house], apartments: %w[apartments],
             hall: %w[industrial retail commercial school office farm hospital parking construction], church: %w[church chapel] }.freeze

  def sample = JSON.parse(Rails.root.join("test/fixtures/files/geleen/classifier_sample.json").read)

  test "houses and sheds are recognised nine times in ten against OSM" do
    %i[house shed].each do |category|
      rows = sample.select { |r| Game::Import::Classifier.category(r) == category }
      agree = rows.count { |r| AGREES[category].include?(r["osm"]) }
      assert_operator agree.to_f / rows.length, :>=, 0.9, "#{category}: #{agree} of #{rows.length}"
    end
  end

  test "a tower on an irregular footprint is a church, and a box of flats is not" do
    church = { "area" => 1212, "h_max" => 23.4, "union_rect" => 0.63, "slenderness" => 3.41, "levels" => nil, "osm" => nil }
    flats = { "area" => 937, "h_max" => 13.1, "union_rect" => 1.0, "slenderness" => 0.43, "levels" => nil, "osm" => nil }
    assert_equal :church, Game::Import::Classifier.category(church)
    assert_equal :apartments, Game::Import::Classifier.category(flats)
  end

  test "an OSM landmark label overrides geometry" do
    box = { "area" => 607, "h_max" => 21.1, "union_rect" => 0.92, "slenderness" => 22.7, "levels" => nil, "osm" => "church" }
    assert_equal :church, Game::Import::Classifier.category(box)
  end
end
```

- [ ] **Step 2: Run, expect failures** (`Game::Import` undefined).

- [ ] **Step 3: Implement**

`dem.rb`:

```ruby
module Game
  module Import
    # A raw Float32 height grid -- the AHN terrain model resampled to ten metres, rows north
    # to south, columns west to east -- read a sample at a time. Knows the file's origin
    # and spacing and nothing else about where it came from.
    class Dem
      class NoData < StandardError; end
      BYTES = 4

      attr_reader :path, :origin_x, :origin_y, :step, :cols, :rows, :nodata

      def initialize(path:, origin_x:, origin_y:, step:, cols:, rows:, nodata: -9999.0)
        @path, @origin_x, @origin_y, @step, @cols, @rows, @nodata = path.to_s, origin_x, origin_y, step, cols, rows, nodata
        @file = File.open(@path, "rb")
      end

      # Bilinear over the four samples around (x, y). Our grid points fall on this grid's
      # pixel edges, so a straight read would pick a corner at random; the blend is smooth.
      def height_at(x, y)
        fx = (x - origin_x) / step - 0.5
        fy = (origin_y - y) / step - 0.5
        col = fx.floor
        row = fy.floor
        raise NoData, "(#{x}, #{y}) is outside the grid" if col < 0 || row < 0 || col + 1 >= cols || row + 1 >= rows

        tx = fx - col
        ty = fy - row
        h00 = sample(row, col)
        h01 = sample(row, col + 1)
        h10 = sample(row + 1, col)
        h11 = sample(row + 1, col + 1)
        (h00 * (1 - tx) + h01 * tx) * (1 - ty) + (h10 * (1 - tx) + h11 * tx) * ty
      end

      private
        def sample(row, col)
          @file.seek((row * cols + col) * BYTES)
          value = @file.read(BYTES).unpack1("e")
          raise NoData, "no data at row #{row}, col #{col}" if value.nil? || value <= nodata + 1 || value.nan?

          value
        end
    end
  end
end
```

`classifier.rb`:

```ruby
module Game
  module Import
    # One Pand in, one category out, from cheap geometry: footprint area, tallest part,
    # rectangularity of the outline, slenderness of the most slender part, floor count,
    # and the OSM label where it names a landmark. Thresholds were swept against 1,875
    # OSM-labelled Pand in Geleen-Noord: houses 95%, sheds 99%, apartments 65%.
    module Classifier
      LANDMARKS = { "church" => :church, "chapel" => :church }.freeze

      def self.category(features)
        f = features.transform_keys(&:to_s)
        return LANDMARKS[f["osm"]] if LANDMARKS.key?(f["osm"])

        area = f["area"].to_f
        h = f["h_max"].to_f
        rect = f["union_rect"].to_f
        slender = f["slenderness"].to_f
        levels = f["levels"].to_i

        # A tower on an irregular footprint. Checked first: a church is mostly nave and
        # would otherwise read as a hall.
        return :church if slender > 2.0 && area > 300 && rect < 0.75
        # Nothing this low is lived in, and nothing this small is a house.
        return :shed if h < 4.0 && area < 60
        return :shed if area < 30
        # Big, low and boxy: a supermarket, a workshop, a school wing.
        return :hall if area > 400 && h < 9.0 && rect > 0.6
        # Three full storeys and bigger than a house, or many floors: flats.
        return :apartments if (area > 120 && h > 9.5) || levels >= 4
        return :hall if area > 400 && rect > 0.6
        return :church if area > 500 && rect < 0.6 && h > 10
        :house
      end
    end
  end
end
```

- [ ] **Step 4: Run** the two files → PASS; `bin/rails test` → 0 failures.

- [ ] **Step 5: Commit**

```bash
git add app/models/game/import test/models/game/import test/fixtures/files/geleen/classifier_sample.json
git commit -m "Add the importer's DEM reader and building classifier"
```

---

### Task 11: Importer stages that turn data into recipes, tiles and fixtures, and the rake task

**Files:**
- Create: `app/models/game/import/rows.rb`, `app/models/game/import/tiles.rb`, `app/models/game/import/fixtures.rb`
- Create: `lib/import/geleen/{window.sql,rows.sql,features.sql,roads.sql}` (from `docs/superpowers/spikes/2026-09-18-dassenkuillaan/sql/`, parametrised on centre and radius with `psql` variables `:cx :cy :radius`, and a bounds envelope for roads)
- Create: `lib/tasks/geleen.rake`
- Create: `test/fixtures/files/geleen/{window.json,rows.json,roads.json}` (the spike's exports, copied from the spike folder's `data/`; `roads.json` produced by `roads.sql` once)
- Test: `test/models/game/import/rows_test.rb`, `test/models/game/import/tiles_test.rb`, `test/models/game/import/fixtures_test.rb`

**Interfaces:**
- Consumes: `Game::Building::RowGenerator.clip` (Task 6), `Row` (Task 5), `Dem` and `Classifier` (Task 10), `TileBuilder.encode`, `Frame.mijnstreek`.
- Produces:
  - `Game::Import::Rows.new(window:, clusters:, frame:, roads:)` → `#objects` → array of `{ name:, x:, z:, yaw:, radius:, recipe: Hash (the row recipe), category:, pands: }` in game coordinates (`y` not yet set).
  - `Game::Import::Tiles.new(dem:, frame:, origin_z:)` → `#encode(tx, tz)` → `TileBuilder::Encoded`; `#ground(gx, gz)` → game metres.
  - `Game::Import::Fixtures.new(slug:, name:, frame:, origin_z:, bounds:, spawns:, roads:, objects:, tiles:, attribution:)` → `#world_yaml`, `#objects_yaml`, `#tiles_yaml` strings.
  - `bin/rails geleen:import` writes the three files.

- [ ] **Step 1: Failing tests**

`rows_test.rb` (the spike's window as input, so the numbers are the spike's):

```ruby
require "test_helper"

class Game::Import::RowsTest < ActiveSupport::TestCase
  def files = Rails.root.join("test/fixtures/files/geleen")
  def rows
    @rows ||= Game::Import::Rows.new(
      window: JSON.parse(files.join("window.json").read), clusters: JSON.parse(files.join("rows.json").read),
      frame: Game::Terrain::Frame.mijnstreek, roads: JSON.parse(files.join("roads.json").read)
    )
  end

  test "the window clusters into fourteen dwelling rows and sixteen shed huddles" do
    objects = rows.objects
    houses = objects.select { |o| o[:category] == "house" }
    assert_equal 30, objects.length
    assert_equal 14, houses.length
    assert_equal [ 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 4, 4 ], houses.map { |o| o[:recipe]["dwellings"].length }.sort
  end

  test "every recipe generates, carries its bays, and lands where the frame says" do
    rows.objects.each do |o|
      set = Game::Building::Generator.call(o[:recipe])
      assert_operator set.piece_count, :>, 0, o[:name]
      assert_equal o[:recipe]["dwellings"].length.clamp(1, 99), set.bays.length if o[:recipe]["dwellings"].any?
      assert_operator o[:radius], :<, 125, "#{o[:name]} would not fit a chunk"
    end
    centre = rows.objects.sum { |o| o[:x] } / 30.0
    assert_in_delta 1330.0, centre, 40.0, "the estate sits where Dassenkuillaan is in the mijnstreek frame"
  end

  test "a row's street side faces its nearest road" do
    row12 = rows.objects.find { |o| o[:recipe]["pands"].include?("053076") }
    x, z = row12[:x], row12[:z]
    yaw = row12[:yaw]
    mid = (row12[:recipe]["dwellings"].first["x0"] + row12[:recipe]["dwellings"].last["x1"]) / 2.0
    front = [ x + mid * Math.cos(yaw) - (-6) * Math.sin(yaw), z + mid * Math.sin(yaw) + (-6) * Math.cos(yaw) ]
    back = [ x + mid * Math.cos(yaw) - 15 * Math.sin(yaw), z + mid * Math.sin(yaw) + 15 * Math.cos(yaw) ]
    assert_operator rows.road_distance(*front), :<, rows.road_distance(*back)
  end
end
```

`tiles_test.rb`:

```ruby
require "test_helper"

class Game::Import::TilesTest < ActiveSupport::TestCase
  # A DEM that is exactly its own NAP height everywhere: 64 m, the estate's ground.
  def tiles
    path = Rails.root.join("tmp/dem_flat.raw")
    path.binwrite(([ 64.0 ] * (60 * 60)).pack("e*"))
    dem = Game::Import::Dem.new(path: path, origin_x: 185_900.0, origin_y: 332_600.0, step: 10.0, cols: 60, rows: 60)
    Game::Import::Tiles.new(dem: dem, frame: Game::Terrain::Frame.mijnstreek, origin_z: 60.0)
  end

  test "a tile is encoded from the DEM in game metres above origin_z" do
    tile = tiles.encode(2, -5)
    metres = Game::Terrain::HeightsCodec.unpack(tile.heights, tile.base_cm)

    assert_equal 51 * 51, metres.length
    assert_in_delta 4.0, metres[1300], 1e-6
    assert_in_delta 4.0, tiles.ground(1330.0, -2234.0), 1e-6
  end
end
```

`fixtures_test.rb`:

```ruby
require "test_helper"

class Game::Import::FixturesTest < ActiveSupport::TestCase
  def fixtures
    Game::Import::Fixtures.new(
      slug: "sample", name: "Sample", frame: Game::Terrain::Frame.mijnstreek, origin_z: 60.0,
      bounds: [ 0, 0, 100, 100 ], spawns: [ { "position" => [ 1.0, 6.0, 2.0 ], "yaw" => 0.5 } ],
      roads: [ { "kind" => "residential", "width" => 5.5, "points" => [ [ 0, 0 ], [ 10, 0 ] ] } ],
      objects: [ { name: "row-0", x: 1.0, y: 4.0, z: 2.0, yaw: 0.1, radius: 12.0, category: "house", pands: %w[1],
                   recipe: { "kind" => "row", "yaw" => 0.1, "cell" => 1.0, "seed" => 1, "band" => [ 0.0, 9.0 ], "storeys" => 2,
                             "storey_height" => 3.0, "eaves" => 6.0, "ridge" => 8.5, "roof" => "gable",
                             "dwellings" => [ { "x0" => 0.0, "x1" => 6.0 } ], "boxes" => [], "footprint" => [ [ 0, 0 ], [ 6, 0 ], [ 6, 9 ], [ 0, 9 ] ],
                             "category" => "house", "pands" => %w[1] } } ],
      tiles: [ Game::Terrain::TileBuilder.encode(frame: Game::Terrain::Frame.mijnstreek, tx: 0, tz: 0) { 4.0 } ],
      attribution: "test"
    )
  end

  test "the fixtures load as rows with the counts the generator produces" do
    world = YAML.safe_load(fixtures.world_yaml, permitted_classes: [ Symbol ])["sample"]
    objects = YAML.safe_load(fixtures.objects_yaml, permitted_classes: [ Symbol ])
    tiles = YAML.unsafe_load(fixtures.tiles_yaml)

    assert_equal "sample", world["slug"]
    assert_equal 60.0, world["origin_z"]
    assert_equal 1, world["roads"].length
    row = objects["sample_row_0"]
    assert_equal "building", row["kind"]
    assert_equal Game::Building::Generator.call(row["recipe"]).piece_count, row["piece_count"]
    assert_equal 51 * 51 * 2, tiles["sample_tile_0_0"]["heights"].bytesize
  end

  test "every file opens with the attribution" do
    [ fixtures.world_yaml, fixtures.objects_yaml, fixtures.tiles_yaml ].each { |yaml| assert yaml.start_with?("# "), "no header" }
    assert_includes fixtures.objects_yaml, "test"
  end
end
```

- [ ] **Step 2: Copy the inputs and run, expect failures**

```bash
cp docs/superpowers/spikes/2026-09-18-dassenkuillaan/data/window.json docs/superpowers/spikes/2026-09-18-dassenkuillaan/data/rows.json test/fixtures/files/geleen/
```

`roads.json` comes from `lib/import/geleen/roads.sql` (Step 3) run once for the estate window. Run the three tests → `Game::Import::Rows` undefined.

- [ ] **Step 3: Implement `Rows`** — a port of the spike's `build_world.rb` `build_cluster` into a class:

```ruby
module Game
  module Import
    # Clusters of 3DBAG parts in, row recipes out. Everything the spike's build_world.rb
    # decided, as a class with one job per method: frame a cluster, find its street side,
    # slice the shared depth into dwellings, turn every other part into a box.
    class Rows
      DWELLING_EAVES = 4.0        # a main part lower than this is a shed
      STOREY_TARGET = 2.8
      CELLS = { "house" => 1.0, "shed" => 1.0, "church" => 2.0, "hall" => 2.0, "apartments" => 1.5 }.freeze

      Frame = Struct.new(:origin, :yaw, keyword_init: true) do
        def u = [ Math.cos(yaw), Math.sin(yaw) ]
        def v = [ -Math.sin(yaw), Math.cos(yaw) ]
        def to_local(gx, gz) = [ (gx - origin[0]) * u[0] + (gz - origin[1]) * u[1], (gx - origin[0]) * v[0] + (gz - origin[1]) * v[1] ]
        def to_world(lx, lz) = [ origin[0] + lx * u[0] + lz * v[0], origin[1] + lx * u[1] + lz * v[1] ]
        def normalised(points)
          locals = points.map { |gx, gz| to_local(gx, gz) }
          Frame.new(origin: to_world(locals.map(&:first).min, locals.map(&:last).min), yaw: yaw)
        end
        def flipped = Frame.new(origin: origin, yaw: yaw + Math::PI)
      end

      def initialize(window:, clusters:, frame:, roads:, categories: nil)
        @parts = window["parts"].to_h { |p| [ p["id"], p ] }
        @clusters = clusters
        @frame = frame
        @roads = roads.map { |r| r["points"].map { |x, y| frame.to_game(x, y) } }
        @categories = categories || {}
      end

      def objects = @clusters.map { |c| build(c) }

      def road_distance(gx, gz)
        @roads.map { |line| line.each_cons(2).map { |(x1, z1), (x2, z2)| segment_distance(gx, gz, x1, z1, x2, z2) }.min }.compact.min || Float::INFINITY
      end

      private
        def ring(geojson)
          coords = geojson["type"] == "MultiPolygon" ? geojson["coordinates"].max_by { |poly| area(poly[0]) } : geojson["coordinates"]
          pts = coords[0].map { |x, y| @frame.to_game(x, y) }
          pts.pop if pts.first == pts.last
          pts
        end

        def area(pts) = pts.each_with_index.sum { |(x1, y1), i| x2, y2 = pts[(i + 1) % pts.length]; x1 * y2 - x2 * y1 }.abs / 2.0
        def centroid(pts) = [ pts.sum(&:first) / pts.size, pts.sum(&:last) / pts.size ]
        def bbox(pts) = [ pts.map(&:first).min, pts.map(&:last).min, pts.map(&:first).max, pts.map(&:last).max ]
        def median(values) = values.sort.then { |s| s.size.odd? ? s[s.size / 2] : (s[s.size / 2 - 1] + s[s.size / 2]) / 2.0 }
        def part_height(p) = p["eaves"] && p["ridge"] ? (p["eaves"] + p["ridge"]) / 2.0 : p["h70"]

        def axis_of(env)
          a, b, c = env[0], env[1], env[2]
          e1 = [ b[0] - a[0], b[1] - a[1] ]
          e2 = [ c[0] - b[0], c[1] - b[1] ]
          long = Math.hypot(*e1) >= Math.hypot(*e2) ? e1 : e2
          Math.atan2(long[1], long[0])
        end

        def segment_distance(px, pz, x1, z1, x2, z2)
          dx, dz = x2 - x1, z2 - z1
          l2 = dx * dx + dz * dz
          t = l2.zero? ? 0.0 : (((px - x1) * dx + (pz - z1) * dz) / l2).clamp(0.0, 1.0)
          Math.hypot(px - (x1 + t * dx), pz - (z1 + t * dz))
        end

        def build(c)
          mains = c["main_ids"].map { |id| @parts[id] }
          members = c["pands"].flat_map { |pand| @parts.values.select { |p| p["pand"] == pand } }
          annexes = members - mains
          houses = mains.all? { |m| (m["eaves"] || m["h70"]) >= DWELLING_EAVES }
          category = @categories[c["pands"].first] || (houses ? "house" : "shed")
          env = ring(c["envelope"])

          # The row runs along one of the envelope's edge directions; the dwellings'
          # centroids say which of the two.
          yaw = axis_of(env)
          if houses && mains.size >= 2
            cs = mains.map { |m| centroid(ring(m["env"])) }
            along = cs.map { |x, z| x * Math.cos(yaw) + z * Math.sin(yaw) }
            across = cs.map { |x, z| -x * Math.sin(yaw) + z * Math.cos(yaw) }
            yaw += Math::PI / 2 if across.max - across.min > along.max - along.min
          end
          everything = members.flat_map { |p| ring(p["geom"]) } + ring(c["union"])
          frame = Frame.new(origin: env[0], yaw: yaw).normalised(everything)

          # The street side: the nearer road when the two long sides differ by more than
          # three metres, else the side the annexes are not on.
          probe = houses ? mains.flat_map { |m| ring(m["env"]) } : ring(c["union"])
          ux0, uz0, ux1, uz1 = bbox(probe.map { |g| frame.to_local(*g) })
          d_min = road_distance(*frame.to_world((ux0 + ux1) / 2, uz0))
          d_max = road_distance(*frame.to_world((ux0 + ux1) / 2, uz1))
          flip = if (d_min - d_max).abs > 3.0 then d_max < d_min
                 elsif annexes.any? && houses
                   mz = mains.sum { |m| centroid(ring(m["env"]).map { |g| frame.to_local(*g) })[1] } / mains.size
                   az = annexes.sum { |p| centroid(ring(p["simple"]).map { |g| frame.to_local(*g) })[1] } / annexes.size
                   az < mz
                 else false end
          frame = frame.flipped.normalised(everything) if flip

          local = ->(part, key) { ring(part[key]).map { |g| frame.to_local(*g) } }
          seed = c["pands"].first[-6..].to_i % 1000
          recipe = { "kind" => "row", "category" => category, "pands" => c["pands"].map { |p| p[-6..] },
                     "yaw" => frame.yaw.round(5), "cell" => CELLS.fetch(category, 1.0), "seed" => seed,
                     "dwellings" => [], "boxes" => [] }

          if houses
            boxes = mains.map { |m| [ m, bbox(local.call(m, "env")) ] }.sort_by { |_, b| (b[0] + b[2]) / 2 }
            band_z0 = boxes.map { |_, b| b[1] }.max
            band_z1 = boxes.map { |_, b| b[3] }.min
            if band_z1 - band_z0 < 5.0
              band_z0 = median(boxes.map { |_, b| b[1] })
              band_z1 = median(boxes.map { |_, b| b[3] })
            end
            xs = boxes.map { |_, b| [ b[0], b[2] ] }
            bounds = [ xs.first[0] ] + xs.each_cons(2).map { |a, b| (a[1] + b[0]) / 2.0 } + [ xs.last[1] ]
            recipe["dwellings"] = boxes.each_index.map { |i| { "x0" => bounds[i].round(2), "x1" => bounds[i + 1].round(2) } }
            recipe["band"] = [ band_z0.round(2), band_z1.round(2) ]
            eaves = mains.map { |m| m["eaves"] || m["h70"] * 0.75 }.max
            ridge = median(mains.map { |m| m["ridge"] || m["h70"] * 1.1 })
            storeys = [ (eaves / STOREY_TARGET).round, 1 ].max
            recipe.merge!("eaves" => eaves.round(2), "ridge" => [ ridge, eaves ].max.round(2), "storeys" => storeys,
                          "storey_height" => (eaves / storeys).round(3), "roof" => ridge - eaves > 0.8 ? "gable" : "flat")
            # A main that reaches past the shared band keeps the excess as a full-height box.
            boxes.each_with_index do |(m, _), i|
              [ [ band_z1, 1 ], [ band_z0, -1 ] ].each do |at, side|
                over = Building::RowGenerator.clip(local.call(m, "simple"), 1, at, side)
                next if over.size < 3 || area(over) < 4.0
                recipe["boxes"] << { "ring" => over.map { |x, z| [ x.round(2), z.round(2) ] }, "eaves" => (m["eaves"] || eaves).round(2),
                                     "ridge" => (m["eaves"] || eaves).round(2), "storeys" => storeys, "roof" => "flat", "door" => false, "solid" => false,
                                     "bay" => i, "name" => "#{m['source_id'][-8..]} overflow" }
              end
            end
            annexes.each do |p|
              ring = local.call(p, "simple").map { |x, z| [ x.round(2), z.round(2) ] }
              recipe["boxes"] << { "ring" => ring, "eaves" => part_height(p).round(2), "ridge" => part_height(p).round(2), "storeys" => 1,
                                   "roof" => "flat", "door" => false, "solid" => false, "bay" => bay_of(recipe["dwellings"], ring), "name" => p["source_id"][-8..] }
            end
          else
            recipe.merge!("band" => [ 0.0, 0.0 ], "storeys" => [ mains.map { |m| ((m["eaves"] || m["h70"]) / 4.0).round }.max, 1 ].max,
                          "storey_height" => 3.0, "eaves" => mains.map { |m| part_height(m) }.max.round(2), "roof" => "flat")
            recipe["ridge"] = recipe["eaves"]
            (mains + annexes).sort_by { |p| -p["area"] }.each_with_index do |p, i|
              ring = local.call(p, category == "church" ? "simple" : "env").map { |x, z| [ x.round(2), z.round(2) ] }
              eaves = p["eaves"] || p["h70"] * 0.8
              ridge = p["ridge"] || p["h70"] * 1.1
              roof = if category == "church" && p["h70"] / Math.sqrt(p["area"]) > 1.8 && p["area"] < 120 then "pyramid"
                     elsif category == "church" && ridge - eaves > 1.5 then "gable"
                     else "flat" end
              storeys = category == "church" ? [ (eaves / 4.0).round, 1 ].max : 1
              recipe["boxes"] << { "ring" => ring, "eaves" => eaves.round(2), "ridge" => [ ridge, eaves ].max.round(2), "storeys" => storeys,
                                   "roof" => roof, "door" => category == "church" && i.zero?, "solid" => category == "shed", "bay" => i, "name" => p["source_id"][-8..] }
            end
            recipe["storeys"] = recipe["boxes"].map { |b| b["storeys"] }.max
          end
          recipe["footprint"] = ring(c["union"]).map { |g| frame.to_local(*g) }.map { |x, z| [ x.round(2), z.round(2) ] }

          radius = everything.map { |g| Math.hypot(*frame.to_local(*g)) }.max + 4.0
          { name: "#{category == 'house' ? 'row' : category}-#{c['cluster']}", x: frame.origin[0].round(3), z: frame.origin[1].round(3),
            yaw: frame.yaw.round(5), radius: radius.round(1), category: category, pands: c["pands"], recipe: recipe }
        end

        # The dwelling a box overlaps most along the row.
        def bay_of(dwellings, ring)
          xs = ring.map(&:first)
          dwellings.each_index.max_by { |i| [ [ dwellings[i]["x1"], xs.max ].min - [ dwellings[i]["x0"], xs.min ].max, 0 ].max } || 0
        end
    end
  end
end
```

`tiles.rb`:

```ruby
module Game
  module Import
    # Heightfield tiles from a survey grid, in the world's frame and above its origin_z.
    class Tiles
      def initialize(dem:, frame:, origin_z:)
        @dem, @frame, @origin_z = dem, frame, origin_z
      end

      def ground(gx, gz)
        x, y = @frame.to_source(gx, gz)
        @dem.height_at(x, y) - @origin_z
      end

      def encode(tx, tz) = Terrain::TileBuilder.encode(frame: @frame, tx: tx, tz: tz) { |gx, gz| ground(gx, gz) }
    end
  end
end
```

`fixtures.rb` writes YAML by hand so the files are readable, each opening with the attribution header; entries `#{slug}` (world), `#{slug}_#{name.tr('-', '_')}` (objects, `kind: building`, `piece_count`/`storey_count` from the generated set, `cx`/`cz` from `frame.chunk_of`), `#{slug}_tile_#{tx}_#{tz}` (tiles, `heights: !!binary` base64). Use `YAML.dump` per entry on a plain Hash and prepend the header.

- [ ] **Step 4: The SQL and the rake task**

Copy the spike's `window.sql`, `rows.sql`, `hood_pand.sql` into `lib/import/geleen/` as `window.sql`, `rows.sql`, `features.sql`, replacing the literal centre with `:cx`, `:cy`, `:radius` (`ST_SetSRID(ST_MakePoint(:cx, :cy), 28992)`, `ST_DWithin(..., :radius)`), and add `roads.sql`:

```sql
WITH box AS (SELECT ST_MakeEnvelope(:x0, :y0, :x1, :y1, 28992) AS g)
SELECT json_agg(json_build_object('kind', r.highway, 'width', r.width, 'points', (
  SELECT json_agg(json_build_array(round(ST_X(p.geom)::numeric, 2), round(ST_Y(p.geom)::numeric, 2)) ORDER BY p.path)
  FROM ST_DumpPoints(g.geom) p)))
FROM roads r, box, LATERAL ST_Dump(ST_Intersection(r.geom, box.g)) g
WHERE ST_Intersects(r.geom, box.g) AND r.highway IN ('residential', 'living_street', 'tertiary', 'secondary', 'service', 'cycleway')
  AND GeometryType(g.geom) = 'LINESTRING';
```

`lib/tasks/geleen.rake`:

```ruby
# Builds the geleen world from 3DBAG (TU Delft, CC BY 4.0), BAG (Kadaster), AHN (PDOK, CC0)
# and OpenStreetMap (ODbL), all read once and written into fixtures beside the hand-made
# worlds. The sibling app's PostGIS database is read-only here, by PGOPTIONS as well as by
# rule; the AHN grid is the sibling's 10 m resample of PDOK's dtm_05m.
namespace :geleen do
  DB = ENV.fetch("GELEEN_DB", "mijnstreek_drive_development")
  DEM = ENV.fetch("GELEEN_DEM", File.expand_path("~/Developer/mijnstreek/data/dem.raw"))
  ISLANDS = [ { name: "estate", cx: 186_330, cy: 332_234, radius: 50 }, { name: "church", cx: 187_006, cy: 331_447, radius: 60 } ].freeze
  BOUNDS = [ 1150, -2350, 2100, -1350 ].freeze
  ORIGIN_Z = 60.0

  def query(file, vars)
    args = vars.flat_map { |k, v| [ "-v", "#{k}=#{v}" ] }
    out, err, status = Open3.capture3({ "PGOPTIONS" => "-c default_transaction_read_only=on" }, "psql", "-d", DB, "-Atq", *args, "-f", Rails.root.join("lib/import/geleen", file).to_s)
    raise "psql #{file}: #{err}" unless status.success?
    JSON.parse(out)
  end

  desc "Import the two islands into test/fixtures/{worlds,world_objects,terrain_tiles}/geleen.yml"
  task import: :environment do
    frame = Game::Terrain::Frame.mijnstreek
    x0, y0 = frame.to_source(BOUNDS[0], BOUNDS[3])
    x1, y1 = frame.to_source(BOUNDS[2], BOUNDS[1])
    roads = query("roads.sql", x0: x0, y0: y0, x1: x1, y1: y1)
    game_roads = roads.map { |r| { "kind" => r["kind"], "width" => r["width"], "points" => r["points"].map { |x, y| frame.to_game(x, y).map { |v| v.round(2) } } } }

    dem = Game::Import::Dem.new(path: DEM, origin_x: 165_500.0, origin_y: 423_500.0, step: 10.0, cols: 5050, rows: 11_850)
    tiles = Game::Import::Tiles.new(dem: dem, frame: frame, origin_z: ORIGIN_Z)

    objects = ISLANDS.flat_map do |island|
      vars = { cx: island[:cx], cy: island[:cy], radius: island[:radius] }
      window = query("window.sql", vars)
      clusters = query("rows.sql", vars)
      features = query("features.sql", vars).to_h { |f| [ f["pand"], Game::Import::Classifier.category(f).to_s ] }
      Game::Import::Rows.new(window: window, clusters: clusters, frame: frame, roads: roads, categories: features).objects
        .map { |o| o.merge(name: "#{island[:name]}-#{o[:name]}") }
    end
    # One base per row: the mean ground under the corners of its dwellings' rectangle, or of its footprint.
    objects.each do |o|
      ring = o[:recipe]["footprint"]
      corners = [ [ ring.map(&:first).min, ring.map(&:last).min ], [ ring.map(&:first).max, ring.map(&:last).min ],
                  [ ring.map(&:first).max, ring.map(&:last).max ], [ ring.map(&:first).min, ring.map(&:last).max ] ]
      yaw = o[:yaw]
      o[:y] = (corners.sum { |lx, lz| tiles.ground(o[:x] + lx * Math.cos(yaw) - lz * Math.sin(yaw), o[:z] + lx * Math.sin(yaw) + lz * Math.cos(yaw)) } / 4.0).round(3)
    end

    encoded = (2..4).flat_map { |tx| (-5..-3).map { |tz| tiles.encode(tx, tz) } }
    spawns = [
      { "position" => [ 1330.0, (tiles.ground(1330.0, -2234.0) + 2.0).round(2), -2234.0 ], "yaw" => 0.82 },
      { "position" => [ 2006.0, (tiles.ground(2006.0, -1415.0) + 2.0).round(2), -1415.0 ], "yaw" => 3.14 }
    ]
    attribution = "Generated by bin/rails geleen:import on #{Date.today}. Buildings: 3D BAG (TU Delft, CC BY 4.0) over BAG (Kadaster). " \
                  "Terrain: AHN dtm_05m (PDOK, CC0) resampled to 10 m. Roads: OpenStreetMap contributors (ODbL). " \
                  "Islands: #{ISLANDS.map { |i| "#{i[:name]} #{i[:radius]} m around RD (#{i[:cx]}, #{i[:cy]})" }.join('; ')}. Do not edit by hand."
    fixtures = Game::Import::Fixtures.new(slug: "geleen", name: "Geleen", frame: frame, origin_z: ORIGIN_Z, bounds: BOUNDS, spawns: spawns,
                                          roads: game_roads, objects: objects, tiles: encoded, attribution: attribution)
    { "worlds" => fixtures.world_yaml, "world_objects" => fixtures.objects_yaml, "terrain_tiles" => fixtures.tiles_yaml }.each do |table, yaml|
      path = Rails.root.join("test/fixtures", table, "geleen.yml")
      FileUtils.mkdir_p(path.dirname)
      path.write(yaml)
      puts "wrote #{path.relative_path_from(Rails.root)} (#{yaml.bytesize} bytes)"
    end
    puts "#{objects.length} buildings, #{encoded.length} tiles, #{game_roads.length} roads"
  end
end
```

- [ ] **Step 5: Run** the three test files → PASS; `bin/rails test` → 0 failures.

- [ ] **Step 6: Commit**

```bash
git add app/models/game/import lib/import/geleen lib/tasks/geleen.rake test/models/game/import test/fixtures/files/geleen
git commit -m "Add the geleen importer: rows from clusters, tiles from the DEM, fixtures out"
```

---

### Task 12: The world itself: import, system tests, guide

**Files:**
- Generated: `test/fixtures/worlds/geleen.yml`, `test/fixtures/world_objects/geleen.yml`, `test/fixtures/terrain_tiles/geleen.yml`
- Create: `test/system/geleen_test.rb`, `test/system/bays_test.rb`
- Modify: `test/system/building_labels_test.rb`, `test/system/shots_test.rb`, `test/models/world_summary_test.rb` (summary string of the new world), `CLAUDE.md`, `.claude/launch.json` (drop the `spike` entry)
- Modify: `test/models/game/building/rubble_test.rb` or `test/system/parity_test.rb`: the per-bay pile order proved across languages

**Interfaces:**
- Consumes: everything above. `bin/rails geleen:import`.
- Produces: the `geleen` world in every database that loads fixtures; `window.__arenaPileOrder(id, bay)` hook for the parity check.

- [ ] **Step 1: Import**

Run: `bin/rails geleen:import`. Expected output: three files written, about 90 buildings, 9 tiles, ~250 roads. Then `bin/rails db:seed` for the development database (seeds load fixture sets, which now include the directories). Open `http://localhost:3000/?world=geleen` on the running dev server and look before writing a test: the estate rows at their bearings, the church a kilometre away, roads on the ground, the car grounded on the terrain.

- [ ] **Step 2: Model tests see the new world**

`world_summary_test.rb`: `every building's stored piece count matches` already covers ~90 more buildings; add `assert_match(/\d+ buildings/, worlds(:geleen).summary)`. Run `bin/rails test` → 0 failures. If a stored count mismatches, the importer's `Fixtures` is wrong, not the fixture: fix it and re-import; never edit the generated file.

- [ ] **Step 3: Failing browser tests**

`test/system/geleen_test.rb`:

```ruby
require "application_system_test_case"

# The first world made of real buildings on real ground. Everything here was asserted for
# years against hand-made worlds; this is where a rotated row, a heightfield from a survey
# and roads that are only drawn meet.
class GeleenTest < ApplicationSystemTestCase
  def boot(spawn: nil, match: "geleen-boot")
    visit root_path(params: { world: "geleen", quality: "low", match: match, spawn: spawn }.compact)
    wait_for(timeout: 60, message: "geleen never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
  end

  test "both islands boot with their buildings, roads and ground" do
    boot
    assert_operator page.evaluate_script("window.__arenaBuildingIds().length"), :>=, 80
    assert_empty severe_console_errors
    assert_operator page.evaluate_script("window.__arenaRoadVertices()"), :>, 1000, "the roads are not drawn"
    # The estate stands about four metres above origin_z, the church about five below.
    assert_in_delta 4.5, page.evaluate_script("window.__arenaTerrainHeight(1330, -2234)"), 2.0
    assert_in_delta(-4.5, page.evaluate_script("window.__arenaTerrainHeight(2006, -1447)"), 3.0)
    probe = page.evaluate_script("window.__arenaTerrainProbe(1330, -2234)")
    assert_operator probe["delta"].abs, :<, 1e-3, "physics and render disagree about the ground"
  end

  test "the second spawn is beside the church" do
    boot(spawn: 1)
    x, _, z = page.evaluate_script("window.__arenaVehiclePos()")
    assert_in_delta 2006, x, 30
    assert_in_delta(-1415, z, 30)
  end

  test "a car driven along the estate's street stays on the ground" do
    boot(match: "geleen-drive")
    page.execute_script("window.__arenaInput = { throttle: 1 }")
    sleep 2.5
    page.execute_script("window.__arenaInput = null")
    x, y, z = page.evaluate_script("window.__arenaVehiclePos()")
    ground = page.evaluate_script("window.__arenaTerrainHeight(#{x}, #{z})")
    assert_in_delta ground + 0.9, y, 0.8, "the car is not resting on the terrain"
  end

  test "a row's plate names its category and its Pand" do
    boot
    plate = page.evaluate_script("window.__arenaBuildingLabels().find(l => l.category === 'house')")
    assert plate, "no house plate"
    assert_match(/\A\d{6}\z/, plate["ids"].first)
  end
end
```

`test/system/bays_test.rb`:

```ruby
require "application_system_test_case"

# A terrace falls one dwelling at a time. The spike measured the alternative: with the row
# as the unit, gutting one house left 69% of the row's support and nothing fell.
class BaysTest < ApplicationSystemTestCase
  def boot(match)
    visit_world("geleen", vehicle: "buggy", match: match)
    wait_for(timeout: 60, message: "geleen never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
    page.execute_script(<<~JS)
      window.__row = () => {
        const ids = window.__arenaBuildingIds()
        return ids.find(i => { const s = window.__arenaBuildingSpec(i); return s.category === "house" && new Set(s.surfaces.filter(x => x.kind === "wall").map(x => x.bay ?? 0)).size >= 4 })
      }
      window.__gut = (id, bay) => {
        const spec = window.__arenaBuildingSpec(id)
        const walls = spec.surfaces.filter(s => s.kind === "wall" && s.storey === 0 && !s.between && (s.bay ?? 0) === bay)
        for (const s of walls) for (let i = s.off; i < s.off + s.cols * s.rows; i++) window.__arenaDamagePiece(i, 5000, id)
        return walls.length
      }
    JS
  end

  test "gutting one dwelling drops that dwelling and leaves its neighbours standing" do
    boot("bays-one")
    id = page.evaluate_script("window.__row()")
    assert id, "no row of four in the world"
    neighbour_before = page.evaluate_script("window.__arenaBuildingSpec(#{id}).surfaces.filter(s => (s.bay ?? 0) === 2 && !s.between).length")
    page.evaluate_script("window.__gut(#{id}, 1)")

    wait_for(timeout: 20, message: "the server never condemned the bay") { page.evaluate_script("window.__arenaCollapses()").positive? }
    assert_equal({ "1" => 0 }, page.evaluate_script("window.__arenaBays(#{id})"))
    wait_for(timeout: 20, message: "the bay never finished falling") { page.evaluate_script("window.__arenaFalling()").zero? }
    standing_bay2 = page.evaluate_script(<<~JS, id)
      (() => { const spec = window.__arenaBuildingSpec(arguments[0]); let n = 0
        for (const s of spec.surfaces.filter(s => (s.bay ?? 0) === 2 && !s.between && s.kind !== "rubble"))
          for (let i = s.off; i < s.off + s.cols * s.rows; i++) if (window.__arenaPieceState(i, arguments[0]).standing) n++
        return n })()
    JS
    assert_operator standing_bay2, :>, 0, "the neighbour came down too"
    party = page.evaluate_script("window.__arenaBuildingSpec(#{id}).surfaces.find(s => s.between && s.between.includes(1) && s.storey === 1)")
    assert page.evaluate_script("window.__arenaPieceState(#{party['off']}, #{id}).standing"), "a shared wall was felled"
    rubble = page.evaluate_script("window.__arenaRubble()")
    assert_operator rubble["standing"], :>, 0, "the fallen bay left no wreckage"
    assert_operator rubble["dormant"], :>, rubble["standing"], "the neighbours' wreckage was revealed too"
  end

  test "the client and the server reveal a bay's heaps in the same order" do
    boot("bays-order")
    id = page.evaluate_script("window.__row()")
    record = WorldObject.find(id)
    surface = record.surface_set.surfaces.last
    [ 0, 1 ].each do |bay|
      assert_equal Game::Building::Rubble.pile_indices(surface, bay: bay), page.evaluate_script("window.__arenaPileOrder(#{id}, #{bay})")
    end
  end
end
```

Add the hook in `engine.js` beside `__arenaBays`: `window.__arenaPileOrder = (id, bay) => { const b = this.buildings?.find(id); const s = b?.spec.surfaces.find(x => x.kind === "rubble"); return s ? pileOrder(s, bay) : [] }` (import `pileOrder`).

`building_labels_test.rb`: the imported case is in `geleen_test.rb`; leave the targets case as it is. `shots_test.rb`: add a `"photograph geleen"` test behind `SHOTS=1` that boots `geleen` at high quality, parks 8 m in front of the first house row facing it, shoots, then `?spawn=1`-equivalent by `park` beside the church and shoots.

- [ ] **Step 4: Run** `bin/rails test test/system/geleen_test.rb test/system/bays_test.rb` → PASS.

- [ ] **Step 5: The guide and the spike server**

`CLAUDE.md`: in "Currently", a bullet for `geleen` (two islands, what it is made of, `?spawn=1`); in Architecture, a "Rows and bays" subsection: the `row` recipe, the pinned order, bays and shared walls at half weight, the `[object_id, storey, bay]` wire, roads as ribbons with no colliders, `bin/rails geleen:import` and that the fixtures are generated; the hooks table gains `__arenaBays`, `__arenaPileOrder`, `__arenaRoadVertices`, `__arenaNetErrors`; the useful URLs gain `geleen` and `?spawn=`. Remove the `spike` entry from `.claude/launch.json`, stop the spike server if it runs, and add a line to the spike report's status: superseded by the `geleen` world.

- [ ] **Step 6: The whole suite, once**

Run: `bin/rails test` → 0 failures; then `bin/rails test:system` (serial, under the machine lock, several minutes; do not run it with the dev server on the same checkout's port). Fix what fails by finding the cause, never by loosening an assertion.

- [ ] **Step 7: Commit**

```bash
git add test/fixtures/worlds/geleen.yml test/fixtures/world_objects/geleen.yml test/fixtures/terrain_tiles/geleen.yml test/system/geleen_test.rb test/system/bays_test.rb test/system/shots_test.rb test/models/world_summary_test.rb app/javascript/game/engine.js CLAUDE.md .claude/launch.json docs/superpowers/spikes/2026-09-18-dassenkuillaan/report.md
git commit -m "Add the geleen world: two islands of real buildings on real ground, falling by the bay"
```

---

## Self-review notes

- **Spec coverage.** §1 world → Task 11/12; §2 row recipe, order, boxes, pyramid, two-column door, cell per category → Tasks 5, 6, 11; §3 bays → Tasks 3, 4, 7, 8, 12; §4 batches → Task 1; §5 rounding → Task 2; §6 roads → Task 9; §7 spawn → Task 9; §8 terrain → Tasks 10, 11; §9 importer and fixtures → Tasks 10, 11, 12; §10 overlay → already in place, exercised in Task 12. Edge cases: window-cut rows (importer parameter), overflow boxes (Task 11 `clip`), meeting boxes and boxes against the row (Task 6), a box spanning two dwellings (`bay_of`, Task 11), a bay with fewer storeys (Task 4 `each_cell` iterates only what a bay has), over-budget collapse (unchanged path), legacy rows (Task 7 migration), over-cap batch from an old client (Task 1), DEM holes (`Dem::NoData`), roads outside tiles (clipped to bounds in `roads.sql`).
- **Type consistency.** `Collapse.evaluate(collapsed:)` returns `Result#collapsed` (Task 4) and `ObjectState#settle` returns `[[bay, storey]]` (Task 7), consumed by `apply_batch` as `[object_id, storey, bay]` (Task 7) and by the client's `breaks` handler as `[objectId, storey, bay]` (Task 8). `Row::Box#bay` is required (Task 5) and written by `Rows#bay_of` (Task 11). `RowGenerator.clip` (Task 6) is what `Rows` calls (Task 11). `pileOrder(surface, bay)` (Task 8) mirrors `Rubble.pile_indices(surface, bay:)` (Task 7) and is held to it in `bays_test` (Task 12).
- **Numbers in the worked example** (Task 5) were derived by hand from the sizes in the test's comment; if the implementation disagrees, the comment is the arbiter and the discrepancy is a bug in one of the two.
