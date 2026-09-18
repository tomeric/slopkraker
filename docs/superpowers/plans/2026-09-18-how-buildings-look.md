# How Buildings Look Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every wall read as brick, every roof as tiles and every house as its own house — procedural surface detail painted at boot from numbers in Ruby, a palette per building applied per instance, doors and windows sized like doors and windows, garages where the importer finds them, front gardens with hedges you can drive through, and daylight to see it all in.

**Architecture:** `Game::Material` gains a `look` (pattern, unit, joint, variation, relief, base) and a palette `role`; `Game::Palettes` is a frozen table like `Materials`; both ship in the spec. The client paints three textures per patterned material once at boot (`render/looks.js`), dresses the one `MeshStandardMaterial` each instanced pool already has, and computes texture coordinates in metres along the surface from a per-instance `cellUV` attribute so a bond runs across cells. Colour is `palette[role] × jitter × damage shade`, written where damage darkening already lives: the instance colour. Openings become styles in `Game::Building::Openings`; hedges are `kind: :hedge` surfaces appended after the boxes and before the rubble of a `row`; lawns are draped quads merged into the roads mesh. `low` quality keeps today's flat materials.

**Tech Stack:** Rails 8.1, plain Ruby under `app/models/game/`, three.js 0.170 (vendored at `vendor/javascript/three.js`) with `onBeforeCompile` shader chunks, `InstancedBufferAttribute`, `CanvasTexture`, `PMREMGenerator`; Rapier unchanged. Minitest; system tests in headless Chrome on SwiftShader.

**Spec:** `docs/superpowers/specs/2026-09-18-how-buildings-look-design.md` — read it first. It follows `docs/superpowers/specs/2026-09-18-geleen-two-islands-design.md` (the `row` recipe, bays, the importer) and this plan assumes that one is built, which it is (`main` at `be9920b` or later).

## Global Constraints

- **Every tuning number lives in Ruby and ships in the spec.** Brick size, joint width, variation, relief, palette colours, sky colours, the lawn colour, the tint jitter: all of it arrives in `spec.materials`, `spec.palettes` or `spec.rules`. The JS side holds exactly two constants of the DRAWING's size, `TILE = 2` (metres one texture covers) and `SIZE = 512` (texels per edge), which the spec explicitly places in `render/looks.js`. A painter's own algorithm internals — how many blots plaster scatters, the strength the normal map is differenced at, the lip under a course of tiles — are not tuning and stay with the painter: they say how that pattern is drawn at all, not what it looks like, and nothing in Ruby could name them without naming the algorithm too.
- **Draw calls track materials, never buildings.** No new mesh per building, no new material per building. An `InstancedMesh` is allocated once from `Building.countMaterials` and cannot grow. `street_test` asserts twelve houses cost no more draws than one; `building_test` asserts under 45 draws at `low`.
- **Piece indices are the contract.** Nothing here may change the surfaces of a `building` recipe: `generator_test`'s worked example (23 surfaces, 1553 pieces, offsets `[0, 36, 72, …, 1454]`) and `row_test`'s pair (29 surfaces, 840 pieces) stay exactly as they are. Openings change *patches* (materials per cell), never grids. Hedges add surfaces to a `row` only when the recipe carries `gardens`, and only after the boxes and before the rubble. The `geleen` fixtures are regenerated once (Task 5) and the dev database re-seeded with `bin/rails geleen:seed`, never `db:seed`.
- **`low` is flat on purpose.** No textures, normal maps or environment map at `quality=low`; the suite's timing assertions are calibrated on that fragment cost. Palettes and openings apply at both tiers.
- **Every `Material` needs `chunk:` and `fracture:`**: `materials_test` demands a chunk profile of everything but `void` and `rubble`, and `Patterns.warm` reads `fracture` for every pool.
- **Hedges must never be weighed or felled by a collapse.** They carry `storey: -1` like rubble, are skipped by name in `Collapse#each_cell`, have `structural_weight: 0.0`, and are left out of the rubble mix.
- **The sibling database is read-only**: every `psql` runs under `PGOPTIONS="-c default_transaction_read_only=on"` (the rake task already does). Attribution lines in the fixture headers stay.
- **Testing discipline.** Run the named test file for what changed; `bin/rails test` (the model suite, ~30 s) at the end of each Ruby task; never the full system suite between tasks. System tests take a machine-wide lock and run serially; a dev server runs on port 3100 out of this checkout and must not be killed. `node --check` lives under mise: `$(ls -d ~/.local/share/mise/installs/node/*/bin | head -1)/node --check <file>`.
- **Commits** end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Messages are a sentence saying what and why, in the style of `git log`.

## Decisions taken here that narrow the spec

Recorded so the executor does not re-derive them and the reviewer does not flag them:

- **Palettes carry `brick`, `roof_tile` and `door` only.** The spec's table also lists `mortar` and `frame`. One instance colour cannot colour a joint differently from the face it separates, so mortar is the face's value at `joint_shade` and takes the palette's brick hue; and a window frame is painted into the glass albedo as a darker neutral border, coloured like the pane. A per-palette frame or mortar colour would need a second material, which is a second draw call.
- **Shards and rubble lumps stay flat-coloured.** A shard is a hand-sized fragment on screen for a second; a lump is dust. Falling slabs, which are storey-high and in the air for seconds, DO take the texture and the palette tint.
- **Glass keeps per-cell texture coordinates.** Its frame is drawn round each pane, so the texture spans the cell rather than two metres of wall; a two-cell window shows a mullion.
- **Back gardens are a fixed strip.** Five metres of lawn behind the footprint's back line, full row width, only for a row that has at least one front garden. The BGT `land_covers` table is the better source and is the next pass, as the spec says.
- **Texture units are rounded to divide the tile.** A 2 m tile holds a whole number of courses and a whole number of bricks per course so it repeats seamlessly: a 210 × 65 mm brick comes out 200 × 64.5 mm. Nobody measures.
- **The spec's `dust` and `metal` patterns are dropped.** `Material::PATTERNS` is the seven the client paints. A rubble lump is a shape rather than a surface — it is dust at ten metres and its texture would never be read — and steel's look is the environment map reflecting a horizon, not an albedo. Both take `look: nil` and draw flat, which is what `materials_test` pins by name.
- **A garage door is whole cells, not half metres.** The spec asks for the door inset half a metre from each side of its box. Openings work in cells, so the rule is stated in cells: a cell in from either side where the box's street edge is five cells or more, the whole face under five. Half a metre of a one-metre cell is not a thing a patch can say, and a two-cell garage door in a three-cell box reads as a garage.

## File structure

Ruby (plain objects, no database):
- `app/models/game/material.rb` — `look:` and `role:` attributes, `PATTERNS`, shipped in `to_spec`.
- `app/models/game/materials.rb` — a `look` per patterned material; new `door` and `hedge` entries.
- `app/models/game/palettes.rb` — NEW. The frozen palette table, `ROLES`, `DEFAULT`, `to_spec`.
- `app/models/game/spec.rb` — `palettes:` in the payload; `default_rules` gains `sky`, `gardens`, `looks`.
- `app/models/game/building/openings.rb` — `STYLES`, `style:`, `door_columns`.
- `app/models/game/building/row.rb` — `palette`, `gardens`, a box `door` that may be `"garage"`, validation.
- `app/models/game/building/gardens.rb` — NEW. Hedge surfaces and lawn rectangles from a `Row`.
- `app/models/game/building/row_generator.rb` — styles per wall and box; step 7, hedges; `lawns`.
- `app/models/game/building/generator.rb` — `lawns(recipe)`.
- `app/models/game/building/surface.rb` — `KINDS` gains `:hedge`.
- `app/models/game/building/rubble.rb` — hedges left out of the volumes.
- `app/models/game/damage/collapse.rb` — hedges skipped by name in `each_cell`.
- `app/models/world_object.rb` — `to_building` ships `palette` and `lawns`.
- `app/models/game/import/rows.rb` — palette per row, garages, gardens.

Client:
- `app/javascript/game/render/looks.js` — NEW. Textures painted from `look`s, the metres shader chunk, slab and lawn materials.
- `app/javascript/game/render/piece_meshes.js` — per-pool geometry with `cellUV`, white material colour, per-instance base tint, composed damage tint.
- `app/javascript/game/world/building.js` — writes `cellUV` and the tint per cell; `tintFor`; slab tints; readouts.
- `app/javascript/game/world/buildings.js` — wires `looks`, `palettes`, `rules.looks` through.
- `app/javascript/game/world/falling_pieces.js` — a textured, tinted material per slab entry.
- `app/javascript/game/render/scene.js` — `QUALITY.textures`; sky and fog from `rules.sky`; environment map.
- `app/javascript/game/render/roads_view.js` — lawns draped with the ribbons, one mesh.
- `app/javascript/game/engine.js` — `Looks`, `time`, sun offset, hooks, disposal.
- `app/javascript/controllers/arena_controller.js` — `?time=`.

Tests:
- `test/models/game/materials_test.rb`, NEW `test/models/game/palettes_test.rb`, `test/models/game/spec_test.rb`, NEW `test/models/world_object_test.rb`, `test/models/game/building/row_test.rb`, `test/models/game/damage/collapse_test.rb`, `test/models/game/import/rows_test.rb`.
- NEW `test/system/looks_test.rb`; `test/system/geleen_test.rb`; `test/system/shots_test.rb`; `test/application_system_test_case.rb` (`visit_world` gains `time:`).
- `CLAUDE.md`.

---

### Task 1: A material knows how it is drawn

**Files:**
- Modify: `app/models/game/material.rb`
- Modify: `app/models/game/materials.rb`
- Test: `test/models/game/materials_test.rb`

**Interfaces:**
- Produces: `Game::Material#look` → frozen Hash with symbol keys (`:pattern`, `:base`, `:variation`, `:relief`, and for brick/tiles/planks `:unit`, `:joint`, `:joint_shade`) or `nil`; `Game::Material#role` → Symbol or `nil`; `Game::Material::PATTERNS` → `%w[brick tiles planks plaster concrete glass leaves]`; `to_spec` gains `look:` (the hash, symbol keys — JSON stringifies them) and `role:` (String or nil). New materials `:door` and `:hedge` in `Game::Materials::TABLE`.

- [ ] **Step 1: Write the failing tests**

Append to `test/models/game/materials_test.rb`, before the final `end`:

```ruby
  # --- how it is drawn -------------------------------------------------------------
  #
  # The look is tuning like everything else here: brick size, joint width, how much one
  # brick differs from the next. The client paints textures from these numbers at boot and
  # holds none of its own.

  test "every patterned material says how it is drawn, and ships it" do
    Game::Materials.names.each do |name|
      material = Game::Materials.fetch(name)
      look = material.look
      assert_equal look, material.to_spec[:look], "#{name} does not ship its look"
      next if look.nil?

      assert_includes Game::Material::PATTERNS, look[:pattern], "#{name} draws a pattern nobody paints"
      assert_match(/\A#[0-9a-f]{6}\z/i, look[:base], "#{name} base is not a colour")
      assert_operator look[:variation], :>=, 0
      assert_operator look[:variation], :<, 1.0, "#{name} could vary to black"
      assert_operator look[:relief], :>=, 0
      next unless %w[brick tiles planks].include?(look[:pattern])

      look[:unit].each { |metres| assert_operator metres, :>, 0, "#{name} unit" }
      assert_operator look[:joint], :>, 0
      assert_operator look[:joint], :<, look[:unit].min, "#{name}'s joints are wider than its units"
      assert_operator look[:joint_shade], :>, 0
      assert_operator look[:joint_shade], :<=, 1.0
    end
  end

  test "walls are bricks, roofs are tiles, doors are planks, and steel is flat" do
    assert_equal "brick", Game::Materials.fetch(:brick).look[:pattern]
    assert_equal "tiles", Game::Materials.fetch(:roof_tile).look[:pattern]
    assert_equal "planks", Game::Materials.fetch(:door).look[:pattern]
    assert_equal "glass", Game::Materials.fetch(:glass).look[:pattern]
    assert_nil Game::Materials.fetch(:steel).look, "steel is flat and reflective, not patterned"
    assert_nil Game::Materials.fetch(:rubble).look, "a lump of dust is a shape, not a pattern"
    assert_nil Game::Materials.fetch(:void).look
  end

  # A door is coloured as a door and a deck as timber, and that is the whole difference.
  test "a door is timber that is coloured as a door" do
    door = Game::Materials.fetch(:door)
    timber = Game::Materials.fetch(:timber)

    assert_equal timber.health_per_m2, door.health_per_m2
    assert_equal timber.density, door.density
    assert_equal :door, door.role
    assert_equal "door", door.to_spec[:role]
    assert_nil timber.role
    assert_equal :brick, Game::Materials.fetch(:brick).role
    assert_equal :roof_tile, Game::Materials.fetch(:roof_tile).role
  end

  # A hedge you cannot drive through is the one thing this game must not have.
  test "a hedge is barely there and holds nothing up" do
    hedge = Game::Materials.fetch(:hedge)

    refute_predicate hedge, :structural?
    assert_operator hedge.health_per_m2, :<, Game::Materials.fetch(:glass).health_per_m2
    assert_operator hedge.toll, :<=, 0.1, "leaves should not slow a car"
    assert_equal "leaves", hedge.look[:pattern]
  end
```

Then in the existing test `"wreckage gives way where a wall has to be punched through"`, change the line `next if name == :rubble` to:

```ruby
      # Rubble and hedges both give way; everything else is a wall.
      next if %i[rubble hedge].include?(name)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/models/game/materials_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'look'` (the first new test), and `KeyError: key not found: :door`.

- [ ] **Step 3: Give `Material` a look and a role**

In `app/models/game/material.rb`:

Add after `KINDS`:

```ruby
    # What the client knows how to paint. Ruby's list and looks.js's PATTERNS are the same
    # list, and materials_test holds every material's look to this one.
    PATTERNS = %w[brick tiles planks plaster concrete glass leaves].freeze
```

Change the `attr_reader` to include `:look, :role`, and the signature and body of `initialize`:

```ruby
    attr_reader :name, :health_per_m2, :density, :hardness, :structural_weight,
                :multipliers, :fracture, :colour, :friction, :restitution,
                :opacity, :metalness, :roughness, :chunk, :toll, :look, :role

    def initialize(name:, health_per_m2:, density:, colour:,
                   hardness: 0.0, structural_weight: 1.0, multipliers: {}, fracture: {},
                   friction: 0.8, restitution: 0.05,
                   opacity: 1.0, metalness: 0.05, roughness: 0.85, chunk: nil, toll: 1.0,
                   look: nil, role: nil)
```

and before `freeze` at the end of `initialize`:

```ruby
      # How a surface of this is DRAWN: which pattern, the size of its units in metres,
      # how wide and how dark the joints are, how much one unit differs from the next,
      # how deep the relief reads, and the albedo's base in value space -- light and nearly
      # neutral, because the hue is the palette's (Game::Palettes) and is applied per
      # instance. Nil for anything drawn flat: steel, which is a reflection; dust, which is
      # a shape; void, which is nothing.
      @look = look&.transform_keys(&:to_sym)&.freeze
      # Which palette colour a piece of this takes, or nil for its own colour. A brick wall
      # is coloured by the building's `brick`, its tiles by `roof_tile`, a door by `door`.
      @role = role&.to_sym
```

Add to `to_spec` after `toll: toll`:

```ruby
        toll: toll,
        look: look,
        role: role&.to_s
```

- [ ] **Step 4: Give every patterned material a look, and add `door` and `hedge`**

In `app/models/game/materials.rb`, add the `look:`/`role:` arguments to the existing entries (keep everything else as it is):

`brick` — after `chunk:`:
```ruby
        chunk: { size: [ 0.70, 0.32, 0.38 ], vary: 0.45, jitter: 0.30 },
        # Running bond, half a brick offset per course, mortar recessed and darker.
        look: { pattern: "brick", unit: [ 0.21, 0.065 ], joint: 0.012, joint_shade: 0.55,
                variation: 0.10, relief: 0.6, base: "#ece6e0" },
        role: :brick
```

`concrete`:
```ruby
        chunk: { size: [ 1.10, 0.40, 0.70 ], vary: 0.40, jitter: 0.25 },
        look: { pattern: "concrete", variation: 0.06, relief: 0.15, base: "#dcdee0" }
```

`plaster`:
```ruby
        chunk: { size: [ 0.80, 0.08, 0.55 ], vary: 0.40, jitter: 0.20 },
        look: { pattern: "plaster", variation: 0.04, relief: 0.1, base: "#efece6" }
```

`timber`:
```ruby
        chunk: { size: [ 1.60, 0.16, 0.20 ], vary: 0.35, jitter: 0.08 },
        look: { pattern: "planks", unit: [ 0.14 ], joint: 0.008, joint_shade: 0.5,
                variation: 0.12, relief: 0.4, base: "#e8ddd0" }
```

`glass` — the unit is the frame's width as a share of a one-metre pane:
```ruby
        chunk: { size: [ 0.35, 0.03, 0.30 ], vary: 0.50, jitter: 0.50 },
        # A transparent pane inside an opaque frame. The frame's width is in metres of a
        # one-metre cell; a bigger cell gets a proportionally bigger frame, which is right
        # for a church window.
        look: { pattern: "glass", unit: [ 0.06 ], variation: 0.0, relief: 0.4, base: "#f2f2f2" }
```

`roof_tile`:
```ruby
        chunk: { size: [ 0.50, 0.05, 0.45 ], vary: 0.30, jitter: 0.20 },
        # Overlapping courses: each course's lower edge stands proud with a shadow line.
        look: { pattern: "tiles", unit: [ 0.30, 0.20 ], joint: 0.01, joint_shade: 0.45,
                variation: 0.12, relief: 0.8, base: "#e6e2df" },
        role: :roof_tile
```

Add two new entries after `steel` and before `rubble`:

```ruby
      # A door leaf: timber's numbers, its own palette role, so a door is coloured as a
      # door and a floor deck as timber. Vertical planks.
      door: Material.new(
        name: :door, colour: "#3d4a44",
        health_per_m2: 2.0, density: 600.0,
        structural_weight: 0.5,
        multipliers: { blade: 1.4, bull_bar: 1.3 },
        fracture: { method: "simple", planes: { x: false, y: true, z: false }, fragments: 10 },
        friction: 0.75,
        chunk: { size: [ 1.60, 0.16, 0.20 ], vary: 0.35, jitter: 0.08 },
        look: { pattern: "planks", unit: [ 0.12 ], joint: 0.006, joint_shade: 0.6,
                variation: 0.08, relief: 0.35, base: "#e4dccf" },
        role: :door
      ),

      # A garden hedge. Leaves: barely any health, holds nothing up, costs a car almost
      # nothing to go through. structural_weight is zero and must stay zero for the same
      # reason rubble's is -- a hedge stands at storey -1 and is skipped by the collapse
      # rule, and this is the third defence.
      hedge: Material.new(
        name: :hedge, colour: "#3f6b2e",
        health_per_m2: 0.3, density: 300.0,
        structural_weight: 0.0,
        multipliers: { impact: 1.5, blast: 1.5, blade: 1.5, bull_bar: 1.5, slam: 1.5 },
        fracture: { method: "simple", planes: { x: true, y: false, z: false }, fragments: 4 },
        friction: 0.5, restitution: 0.0,
        chunk: { size: [ 0.45, 0.30, 0.30 ], vary: 0.40, jitter: 0.30 },
        look: { pattern: "leaves", variation: 0.25, relief: 0.5, base: "#dfe6d6" },
        toll: 0.05
      ),
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/models/game/materials_test.rb test/models/game/spec_test.rb`
Expected: PASS (the spec test `"the material table ships with the spec"` compares names, and now includes `door` and `hedge`).

- [ ] **Step 6: Run the model suite and commit**

Run: `bin/rails test`
Expected: PASS. (`world_summary_test` is untouched: no surface changed.)

```bash
git add app/models/game/material.rb app/models/game/materials.rb test/models/game/materials_test.rb
git commit -m "Say how a material is drawn, and add a door and a hedge to the table

A Material gains a look -- pattern, units in metres, joint, variation, relief, a
value-space base -- and a palette role. The client paints textures from these at boot
and holds no numbers of its own. A door is timber coloured as a door; a hedge is
leaves that hold nothing up and cost a car nothing.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Palettes, the sky and the lawn ship in the spec

**Files:**
- Create: `app/models/game/palettes.rb`
- Modify: `app/models/game/spec.rb`
- Modify: `app/models/world_object.rb`
- Modify: `app/models/game/building/row.rb` (palette key + validation only; gardens come in Task 4)
- Test: `test/models/game/palettes_test.rb` (new), `test/models/game/spec_test.rb`, `test/models/world_object_test.rb` (new), `test/models/game/building/row_test.rb`

**Interfaces:**
- Produces: `Game::Palettes::TABLE` (frozen `{ Symbol => { brick:, roof_tile:, door: } }`), `Game::Palettes::ROLES = %i[brick roof_tile door]`, `Game::Palettes::DEFAULT = :brown_brick`, `Game::Palettes.fetch(key)`, `Game::Palettes.key?(key)`, `Game::Palettes.names`, `Game::Palettes.to_spec`. `Game::Spec#to_spec` gains `palettes:`. `Game::Spec.default_rules` gains `sky: { day: {...}, night: {...} }`, `gardens: { grass:, lift: }`, `looks: { jitter: }`. `Game::Building::Row#palette` (String, default `"brown_brick"`). `WorldObject#to_building` gains `palette:`.

- [ ] **Step 1: Write the failing tests**

Create `test/models/game/palettes_test.rb`:

```ruby
require "test_helper"

class Game::PalettesTest < ActiveSupport::TestCase
  test "every palette names every role, as a colour" do
    Game::Palettes::TABLE.each do |name, palette|
      assert_equal Game::Palettes::ROLES.sort, palette.keys.sort, "#{name} is missing a role"
      palette.each_value { |colour| assert_match(/\A#[0-9a-f]{6}\z/i, colour, "#{name}") }
    end
  end

  # A material that names a role the palettes do not carry would be coloured by nothing.
  test "every role a material asks for is one every palette carries" do
    Game::Materials::TABLE.each_value do |material|
      next if material.role.nil?

      assert_includes Game::Palettes::ROLES, material.role, "#{material.name} asks for #{material.role}"
    end
  end

  test "the default palette exists and is what the hand-made worlds are drawn in" do
    assert Game::Palettes.key?(Game::Palettes::DEFAULT)
    assert_equal Game::Materials.fetch(:brick).colour, Game::Palettes.fetch(Game::Palettes::DEFAULT)[:brick],
                 "brown_brick is tuned to reproduce today's brick"
  end

  test "the table serialises with string keys and without leaking ruby objects" do
    round_tripped = JSON.parse(Game::Palettes.to_spec.to_json)

    assert_equal Game::Palettes.names.map(&:to_s).sort, round_tripped.keys.sort
    assert_equal Game::Palettes::ROLES.map(&:to_s).sort, round_tripped["red_brick"].keys.sort
  end
end
```

Append to `test/models/game/spec_test.rb` before the final `end`:

```ruby
  test "the palette table ships with the spec" do
    assert_equal Game::Palettes.names.map(&:to_s).sort, spec[:palettes].keys.map(&:to_s).sort
  end

  # Both skies whole, so the client can build either from the same numbers and the night
  # the game was lit for stays one URL parameter away.
  test "the client is told what the sky looks like, by day and by night" do
    sky = Game::Spec.default_rules.fetch(:sky)

    %i[day night].each do |time|
      entry = sky.fetch(time)
      %i[zenith horizon ground sun].each { |key| assert_match(/\A#[0-9a-f]{6}\z/i, entry.fetch(key), "#{time} #{key}") }
      assert_equal 3, entry.fetch(:hemisphere).length, "#{time} hemisphere is sky colour, ground colour, intensity"
      assert_operator entry.fetch(:sun_intensity), :>, 0
      assert_equal 3, entry.fetch(:sun_direction).length
      assert_operator entry.fetch(:sun_direction)[1], :>, 0, "#{time}'s sun is below the horizon"
      near, far = entry.fetch(:fog)
      assert_operator near, :<, far
    end
    assert_equal "#0e1116", sky.dig(:night, :horizon), "night is the sky the game was lit for until now"
  end

  test "the client is told how to draw a lawn and how much a wall may vary" do
    assert_match(/\A#[0-9a-f]{6}\z/i, Game::Spec.default_rules.dig(:gardens, :grass))
    assert_operator Game::Spec.default_rules.dig(:gardens, :lift), :<, Game::Spec.default_rules.dig(:roads, :lift),
                    "a lawn meeting a road must sit beneath it"
    jitter = Game::Spec.default_rules.dig(:looks, :jitter)
    assert_operator jitter, :>, 0
    assert_operator jitter, :<, 0.2, "a wall should not vary into a patchwork"
  end
```

Create `test/models/world_object_test.rb`:

```ruby
require "test_helper"

class WorldObjectTest < ActiveSupport::TestCase
  test "a hand-made building is drawn in the default palette" do
    assert_equal "brown_brick", world_objects(:targets_house).to_building[:palette]
  end

  test "a recipe's palette ships with its building" do
    house = world_objects(:targets_house)
    house.recipe = house.recipe.merge("palette" => "red_brick")

    assert_equal "red_brick", house.to_building[:palette]
  end
end
```

Append to `test/models/game/building/row_test.rb`, inside the class (before `test "a row is validated"`):

```ruby
  test "a row carries a palette the table knows" do
    assert_equal "brown_brick", Game::Building::Row.from(pair_recipe).palette
    assert_equal "red_brick", Game::Building::Row.from(pair_recipe("palette" => "red_brick")).palette
    assert_raises(Game::Building::Row::Invalid) { Game::Building::Row.from(pair_recipe("palette" => "tartan")) }
  end
```

and refactor the top of the file so the recipe hash is reachable on its own: replace the `pair` helper with

```ruby
  def pair_recipe(**overrides)
    {
      "kind" => "row", "category" => "house", "pands" => %w[000001 000002],
      "yaw" => 0.0, "cell" => 1.0, "seed" => 1,
      "band" => [ 0.0, 9.0 ], "storeys" => 2, "storey_height" => 3.0, "eaves" => 6.0, "ridge" => 8.5, "roof" => "gable",
      "dwellings" => [ { "x0" => 0.0, "x1" => 6.0 }, { "x0" => 6.0, "x1" => 12.0 } ],
      "boxes" => [],
      "footprint" => [ [ 0, 0 ], [ 12, 0 ], [ 12, 9 ], [ 0, 9 ] ]
    }.merge(overrides)
  end

  def pair(**overrides)
    Game::Building::Generator.call(pair_recipe(**overrides))
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/models/game/palettes_test.rb test/models/game/spec_test.rb test/models/world_object_test.rb test/models/game/building/row_test.rb`
Expected: FAIL — `NameError: uninitialized constant Game::Palettes`, the sky/gardens/looks keys missing, `to_building[:palette]` nil, `Row#palette` undefined.

- [ ] **Step 3: Write the palette table**

Create `app/models/game/palettes.rb`:

```ruby
module Game
  # A building's colours are one key. Every recipe carries a palette name; the client
  # multiplies the palette's colour for a material's role into each instance where damage
  # darkening already lives, so one instanced pool still serves every building whatever
  # its palette, and no building costs a draw call of its own.
  #
  # The albedo textures are painted in value space -- light, nearly neutral -- so this
  # multiplication IS the colouring. brown_brick is tuned to reproduce today's colours, so
  # the four hand-made worlds, which name no palette, look like themselves.
  module Palettes
    # brick colours walls and gable ends; roof_tile the roof planes; door the door leaves.
    # Glass, steel, plaster, concrete and timber decks keep their material's own colour.
    ROLES = %i[brick roof_tile door].freeze
    DEFAULT = :brown_brick

    TABLE = {
      brown_brick: { brick: "#a8674a", roof_tile: "#8c3b2e", door: "#5a2a1e" },
      red_brick:   { brick: "#9a4b32", roof_tile: "#7a3a2c", door: "#2f4b3e" },
      sand_brick:  { brick: "#c8a878", roof_tile: "#8d4a35", door: "#33383d" },
      dark_brick:  { brick: "#4e3a33", roof_tile: "#2e3034", door: "#7a2c22" },
      church:      { brick: "#6e4a3a", roof_tile: "#3a3f47", door: "#3a2a22" }
    }.freeze

    def self.fetch(key) = TABLE.fetch(key.to_sym)
    def self.key?(key) = TABLE.key?(key.to_s.to_sym)
    def self.names = TABLE.keys

    def self.to_spec
      TABLE.transform_values { |palette| palette.transform_keys(&:to_s) }
    end
  end
end
```

- [ ] **Step 4: Ship palettes and the new rules**

In `app/models/game/spec.rb`, in `to_spec`, after the `materials:` line:

```ruby
        materials: Materials.to_spec,
        # The colour tables, whole: a recipe names one and the client looks it up.
        palettes: Palettes.to_spec,
```

In `default_rules`, after the `roads:` entry (add a comma after its closing brace):

```ruby
        # The light the world is seen in. Daylight is the default -- brick and tile detail
        # needs light to read -- and the night the game was lit for until now is one URL
        # parameter away (?time=night), because it was a deliberate look and the two should
        # be comparable. Each entry is a whole sky: the gradient the background and the
        # environment map are built from (zenith, horizon, ground), the fog to the horizon
        # colour, the hemisphere light and the sun. Physics does not care, so the suite's
        # timing assertions are unaffected.
        sky: {
          day: { zenith: "#4f86c6", horizon: "#d3dde6", ground: "#4d5a45",
                 hemisphere: [ "#bfd4ec", "#4d5a45", 0.9 ], sun: "#fff1dc", sun_intensity: 2.6,
                 sun_direction: [ 30, 80, 24 ], fog: [ 150, 420 ] },
          night: { zenith: "#0e1116", horizon: "#0e1116", ground: "#2a2f36",
                   hemisphere: [ "#9fb8d0", "#2a2f36", 1.1 ], sun: "#fff4e0", sun_intensity: 2.2,
                   sun_direction: [ 48, 72, 36 ], fog: [ 110, 280 ] }
        },
        # Front gardens are lawns draped beside the road ribbons: their colour, and how far
        # above the ground they float -- under the roads' lift, so a lawn meeting a road
        # sits beneath it.
        gardens: { grass: "#4f7a36", lift: 0.02 },
        # How much one cell's colour may differ from the next, as a share of lightness. A
        # wall of one flat value reads as paint; a few percent, seeded per cell, reads as
        # brick that was fired in a kiln.
        looks: { jitter: 0.03 }
```

- [ ] **Step 5: Ship the palette on a building and validate it on a row**

In `app/models/world_object.rb`, in `to_building`, after `pands: recipe["pands"]`:

```ruby
      pands: recipe["pands"],
      # Which colours it is drawn in. A hand-made recipe names none and gets the default,
      # which is tuned to today's colours so the four worlds look like themselves.
      palette: recipe["palette"] || Game::Palettes::DEFAULT.to_s
```

In `app/models/game/building/row.rb`: add `:palette` to the `attr_reader`, to `from` (`palette: a.fetch("palette", Palettes::DEFAULT.to_s).to_s`), to `initialize`'s keyword list and assignments, and to `validate!`:

```ruby
          raise Invalid, "palette #{palette} is not in the table" unless Palettes.key?(palette)
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bin/rails test test/models/game/palettes_test.rb test/models/game/spec_test.rb test/models/world_object_test.rb test/models/game/building/row_test.rb`
Expected: PASS.

- [ ] **Step 7: Run the model suite and commit**

Run: `bin/rails test`
Expected: PASS.

```bash
git add app/models/game/palettes.rb app/models/game/spec.rb app/models/world_object.rb app/models/game/building/row.rb test/models/game/palettes_test.rb test/models/game/spec_test.rb test/models/world_object_test.rb test/models/game/building/row_test.rb
git commit -m "Ship the palettes, both skies and the lawn in the spec

A building's colours are one key into a frozen table like Materials, applied per
instance so no palette costs a draw call. The day and night skies, the lawn colour
and the per-cell jitter are rules, because every tuning number lives in Ruby.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Openings with meaning

**Files:**
- Modify: `app/models/game/building/openings.rb`
- Modify: `app/models/game/building/row.rb` (a box `door` may be `"garage"`)
- Modify: `app/models/game/building/row_generator.rb` (styles per wall and box)
- Test: `test/models/game/building/row_test.rb`, `test/models/game/building/generator_test.rb` (must stay green, unchanged)

**Interfaces:**
- Consumes: `Game::Materials.fetch(:door)` (Task 1).
- Produces: `Game::Building::Openings::STYLES` (frozen Hash keyed `:classic :house :annex :garage :nave :tower :chapel`), `Openings.new(seed:, style: :classic)`, `Openings#for_wall(edge:, storey:, cols:, rows:)` (unchanged signature), `Openings#door_columns(cols)` → Array of Integer columns the door occupies on the door face (`[]` when none), `Openings#door_face?(edge, storey, cols)`. `RowGenerator.style_for(row, box)` → Symbol or nil. `Row::Box#door` is `true`, `false` or `"garage"`.

- [ ] **Step 1: Write the failing tests**

In `test/models/game/building/row_test.rb`, replace the test `"every dwelling gets a front door at ground level and the party wall gets nothing"` with:

```ruby
  # A three-metre door is a garage. A dwelling's front is a one-cell door with a two-cell
  # window beside it, a pier between; upstairs the windows go every other column as before.
  test "a dwelling's front is a one-cell door with a two-cell window beside it, and no lintel" do
    set = pair
    walls = set.surfaces.select { |s| s.kind == :wall }
    fronts = [ walls[0], walls[4] ]

    fronts.each do |front|
      doors = front.patches.select { |p| p.material == :door }
      windows = front.patches.select { |p| p.material == :glass }
      assert_equal 1, doors.length, "one door"
      door = doors.first
      assert_equal door.col0, door.col1, "a door is one cell wide"
      assert_equal [ 0, 1 ], [ door.row0, door.row1 ], "a door is two rows tall and stands on the ground"
      assert_equal 1, windows.length, "one window on the ground floor of the front"
      window = windows.first
      assert_equal 2, window.col1 - window.col0 + 1, "the front window is two cells wide"
      assert_equal 1, window.row0, "a window sits on a course, not on the floor"
      assert_includes [ window.col0 - door.col1, door.col0 - window.col1 ], 2, "one pier stands between the door and the window"
      assert front.patches.none? { |p| p.material == :steel }, "no lintel over a one-cell door"
      assert front.patches.none? { |p| p.material == :timber }, "the door is a door, not timber"
    end
    upstairs = walls[1]
    assert upstairs.patches.all? { |p| p.material == :glass && p.col0 == p.col1 }, "upstairs windows are one cell"
    assert_empty walls[12].patches, "the party wall gets nothing"
  end

  test "the path columns are the door's" do
    openings = Game::Building::Openings.new(seed: 1, style: :house)
    door = openings.for_wall(edge: 0, storey: 0, cols: 6, rows: 3).find { |p| p.material == :door }

    assert_equal [ door.col0 ], openings.door_columns(6)
    assert_equal [], openings.door_columns(2), "a face too narrow for a door has no path either"
    assert_equal [], Game::Building::Openings.new(seed: 1, style: :annex).door_columns(6)
  end

  # Two rows tall across the face, half a metre in from either side -- or the whole face
  # when the face is under five cells, because a one-cell door on a three-metre garage is
  # a letterbox.
  test "a garage box gets a garage door on its first edge" do
    garage = { "ring" => [ [ 13.0, 0.0 ], [ 19.0, 0.0 ], [ 19.0, 6.0 ], [ 13.0, 6.0 ] ], "eaves" => 2.6, "ridge" => 2.6,
               "storeys" => 1, "roof" => "flat", "door" => "garage", "solid" => false, "bay" => 1, "name" => "garage" }
    set = pair("boxes" => [ garage ], "footprint" => [ [ 0, 0 ], [ 19, 0 ], [ 19, 9 ], [ 0, 9 ] ])
    front = set.surfaces.select { |s| s.kind == :wall }.find { |s| s.origin.x == 13.0 && s.origin.z == 0.0 }

    assert front, "the garage's front wall was not built"
    assert_equal 6, front.cols
    door = front.patches.find { |p| p.material == :door }
    assert door, "no garage door"
    assert_equal [ 1, 4 ], [ door.col0, door.col1 ], "a metre in from either side"
    assert_equal [ 0, 1 ], [ door.row0, door.row1 ], "two rows tall"
    assert front.patches.none? { |p| p.material == :glass }, "a garage front has no windows"

    narrow = pair("boxes" => [ garage.merge("ring" => [ [ 13.0, 0.0 ], [ 16.0, 0.0 ], [ 16.0, 6.0 ], [ 13.0, 6.0 ] ]) ],
                  "footprint" => [ [ 0, 0 ], [ 16, 0 ], [ 16, 9 ], [ 0, 9 ] ])
    small = narrow.surfaces.select { |s| s.kind == :wall }.find { |s| s.origin.x == 13.0 && s.origin.z == 0.0 }
    assert_equal [ 0, 2 ], [ small.patches.find { |p| p.material == :door }.col0, small.patches.find { |p| p.material == :door }.col1 ],
                 "a three-metre garage is all door"
  end

  # A church in miniature: a nave with a two-cell door and tall windows every third column,
  # a tower with one small window per storey, a chapel with windows every other column.
  def church(**overrides)
    nave = { "ring" => [ [ 0, 0 ], [ 24, 0 ], [ 24, 12 ], [ 0, 12 ] ], "eaves" => 10.0, "ridge" => 14.0, "storeys" => 2,
             "roof" => "gable", "door" => true, "solid" => false, "bay" => 0, "name" => "nave" }
    tower = { "ring" => [ [ 30, 2 ], [ 36, 2 ], [ 36, 8 ], [ 30, 8 ] ], "eaves" => 20.0, "ridge" => 27.0, "storeys" => 5,
              "roof" => "pyramid", "door" => false, "solid" => false, "bay" => 1, "name" => "tower" }
    chapel = { "ring" => [ [ 0, 14 ], [ 12, 14 ], [ 12, 20 ], [ 0, 20 ] ], "eaves" => 5.0, "ridge" => 7.0, "storeys" => 1,
               "roof" => "gable", "door" => false, "solid" => false, "bay" => 2, "name" => "chapel" }
    Game::Building::Generator.call(pair_recipe(**{
      "category" => "church", "cell" => 2.0, "dwellings" => [], "boxes" => [ nave, tower, chapel ],
      "band" => [ 0.0, 0.0 ], "storeys" => 5, "storey_height" => 4.0, "eaves" => 20.0, "ridge" => 20.0, "roof" => "flat",
      "footprint" => [ [ 0, 0 ], [ 36, 0 ], [ 36, 20 ], [ 0, 20 ] ]
    }.merge(overrides)))
  end

  test "a church's parts are punctured by what they are" do
    set = church
    walls = set.surfaces.select { |s| s.kind == :wall }
    nave_front = walls.find { |w| w.storey.zero? && w.origin.x == 0.0 && w.origin.z == 0.0 && w.u.x > 0 }
    tower_walls = walls.select { |w| w.origin.x >= 30.0 && w.origin.z >= 2.0 && w.origin.x <= 36.0 && w.origin.z <= 8.0 }
    chapel_walls = walls.select { |w| w.origin.z >= 14.0 }

    assert nave_front, "no nave front"
    door = nave_front.patches.find { |p| p.material == :door }
    assert door, "the nave has no door"
    assert_equal 2, door.col1 - door.col0 + 1, "a church door is two cells wide"
    nave_windows = nave_front.patches.select { |p| p.material == :glass }
    assert_operator nave_windows.length, :>=, 2
    # Every third column, less the one the door displaced: the columns all lie on one
    # rhythm of three, even where a window is missing from it.
    assert nave_windows.all? { |w| (w.col0 - nave_windows.first.col0) % 3 == 0 }, "nave windows every third column: #{nave_windows.map(&:col0)}"

    per_storey = tower_walls.group_by(&:storey).transform_values { |ws| ws.sum { |w| w.patches.count { |p| p.material == :glass } } }
    assert per_storey.values.all? { |n| n.between?(1, 4) }, "a tower has a window or so per storey per face, not a wall of them: #{per_storey}"
    assert tower_walls.none? { |w| w.patches.any? { |p| p.material == :door } }, "no door on the tower"

    chapel_front = chapel_walls.find { |w| w.storey.zero? }
    chapel_windows = chapel_front.patches.select { |p| p.material == :glass }
    assert chapel_windows.each_cons(2).all? { |a, b| b.col0 - a.col0 == 2 }, "chapel windows every other column"
  end

  test "a box door is true, false or a garage" do
    assert_raises(Game::Building::Row::Invalid) { pair("boxes" => [ annex("door" => "hatch") ]) }
    assert_equal "garage", Game::Building::Row.from(pair_recipe("boxes" => [ annex("door" => "garage") ])).boxes.first.door
  end
```

Keep `"the worked example generates exactly what it is supposed to"`, `"a box is walls, then decks, then its roof…"` and `"the building kind still goes the old way"` exactly as they are — they are the proof that nothing renumbered.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/models/game/building/row_test.rb`
Expected: FAIL — `ArgumentError: unknown keyword: :style`, and the door assertions (`:timber` patches, a three-cell door).

- [ ] **Step 3: Rewrite `Openings` around styles**

Replace the body of `app/models/game/building/openings.rb` with:

```ruby
module Game
  module Building
    # Where the windows and the door go, by what the building IS.
    #
    # Openings are whole cells, so the grid decides what a window can be. Sub-cell openings
    # would mean clipping polygons identically in Ruby and in JavaScript; the sibling map
    # app needs six hundred lines of Sutherland-Hodgman for exactly that, and this
    # deliberately does not.
    #
    # Which means the cell size is an architectural decision. At 1m cells a 3m storey is
    # three rows, and that third row is what lets a window sit at eye level instead of on
    # the floor.
    #
    # Deterministic from the recipe's seed, so the same building generates identically
    # every time. It has to: a piece index means nothing if the wall it refers to might
    # have had its windows somewhere else.
    #
    # STYLES change PATCHES -- which cells are glass, door or lintel -- and never grids, so
    # no style changes a piece count or an offset. They live here rather than in the spec
    # because they change surfaces, and the row tests pin them.
    class Openings
      # The ground floor of the first edge gets the door.
      DOOR_EDGE = 0
      DOOR_STOREY = 0
      # A window wants a course beneath it. Where the storey is too short to give it one it
      # sits on the floor, which is at least honest about the grid it is drawn on.
      SILL_ROW = 1

      STYLES = {
        # The single free-standing `building` recipe, EXACTLY as it always was: a
        # three-cell timber door under a steel lintel, centred, windows every other column.
        # The four hand-made worlds are built from this and must not move.
        classic: { door: { cols: 3, rows: 2, material: :timber, lintel: true, at: :centre }, windows: :alternate, tall: 1, ground_sill: 0 },
        # A dwelling's front: a one-cell door near one end with a two-cell window beside
        # it, a pier between, and nothing else on the ground floor of the front. Three
        # metres of door is a garage, and driving through a house never needed the door --
        # you drive through the wall, and the wall is what the game is about.
        house: { door: { cols: 1, rows: 2, material: :door, lintel: false, at: :side }, windows: :alternate, tall: 1, front_window: 2 },
        # An annex, an outbuilding with windows, the end of a row: no door, every other column.
        annex: { door: nil, windows: :alternate, tall: 1 },
        # A garage: a door two rows tall across the face, a cell in from either side when
        # the face is five cells or more, the whole face when it is not.
        garage: { door: { cols: :wide, rows: 2, material: :door, lintel: false, at: :centre }, windows: :none, tall: 1 },
        # A church's parts. The nave gets a two-cell door and tall windows every third
        # column; a tower one small window per storey; a chapel a window every other column.
        nave: { door: { cols: 2, rows: 2, material: :door, lintel: false, at: :centre }, windows: :third, tall: 2 },
        tower: { door: nil, windows: :one, tall: 1 },
        chapel: { door: nil, windows: :alternate, tall: 1 }
      }.freeze

      attr_reader :style

      def initialize(seed:, style: :classic)
        @seed = seed
        @name = style.to_sym
        @style = STYLES.fetch(@name)
      end

      def for_wall(edge:, storey:, cols:, rows:)
        doorway = door(cols, rows) if door_face?(edge, storey, cols)
        front = doorway && style[:front_window] ? front_window(cols, rows, doorway.first) : nil
        windows =
          if front
            # The ground floor of a dwelling's front is the door and its window and nothing
            # else; a third opening on a six-metre face is a shop.
            Array(front)
          else
            window_columns(edge, storey, cols)
              .reject { |col| doorway && doorway.any? { |p| p.covers?(0, col) } }
              .map { |col| window(col, rows) }
          end
        windows + Array(doorway)
      end

      # The columns the door occupies on the door face, or none. A garden path has to meet
      # the door, so the hedge asks this of the same object the front wall was punctured by.
      def door_columns(cols)
        return [] unless door_face?(DOOR_EDGE, DOOR_STOREY, cols)

        first, last = door_span(cols)
        (first..last).to_a
      end

      # A face narrower than three cells gets no door: at one-metre cells a two-cell shed
      # front was all door under a full-width lintel.
      def door_face?(edge, storey, cols)
        !style[:door].nil? && edge == DOOR_EDGE && storey == DOOR_STOREY && cols >= 3
      end

      private
        attr_reader :seed

        def sill(rows)
          return style[:ground_sill] if rows < 3 && style.key?(:ground_sill)

          rows >= 3 ? SILL_ROW : [ rows - 1, 0 ].max
        end

        # One cell wide, `tall` rows when there is a course below and above them, one row
        # otherwise. A two-row window in a two-row storey is a hole, not a window.
        def window(col, rows)
          row = sill(rows)
          height = rows >= style[:tall] + 2 ? style[:tall] : 1
          Surface::Patch.new(col0: col, row0: row, col1: col, row1: row + height - 1, material: :glass)
        end

        # The two-cell window beside a dwelling's door, on the side away from the end the
        # door stands near, with one pier between. None if the face has no room for it.
        def front_window(cols, rows, door)
          left = door.col0 + 2
          right = door.col0 - 3
          col0 = door.col0 < cols / 2 ? left : right
          return nil unless col0 >= 0 && col0 + style[:front_window] - 1 <= cols - 1

          row = sill(rows)
          Surface::Patch.new(col0: col0, row0: row, col1: col0 + style[:front_window] - 1, row1: row, material: :glass)
        end

        def door(cols, rows)
          spec = style[:door]
          first, last = door_span(cols)
          height = [ spec[:rows], rows ].min
          patches = [ Surface::Patch.new(col0: first, row0: 0, col1: last, row1: height - 1, material: spec[:material]) ]
          return patches unless spec[:lintel] && rows > height

          # The one place steel reads as structure rather than as a dark square in the
          # middle of a wall: a lintel actually spanning something.
          patches << Surface::Patch.new(col0: first, row0: height, col1: last, row1: height, material: :steel)
        end

        # Where the door stands. Centred for a classic door, a portal and a garage; near one
        # end for a dwelling, which end decided by the seed so a terrace is not a row of
        # identical fronts. `wide` is the face minus a cell each side, or the whole face
        # under five cells.
        def door_span(cols)
          spec = style[:door]
          case spec[:cols]
          when :wide
            margin = cols >= 5 ? 1 : 0
            [ margin, cols - 1 - margin ]
          else
            width = [ spec[:cols], cols ].min
            first =
              if spec[:at] == :side
                seed.odd? ? cols - 1 - width : 1
              else
                [ (cols - width) / 2, 0 ].max
              end
            [ first, first + width - 1 ]
          end
        end

        # Every other column, offset by the edge and storey so the faces are not identical
        # and the building does not read as wallpaper; every third, the same way, for a
        # nave; the middle column alone for a tower.
        def window_columns(edge, storey, cols)
          case style[:windows]
          when :none then []
          when :one then cols >= 3 ? [ cols / 2 ] : []
          when :third
            return [] if cols < 3

            start = 1 + ((seed + edge) % 2)
            (start...(cols - 1)).step(3).to_a
          else
            return [] if cols < 2

            start = 1 + ((seed + edge * 3 + storey) % 2)
            (start...cols).step(2).to_a
          end
        end
    end
  end
end
```

Note `classic`'s `ground_sill: 0` reproduces the old `rows >= 3 ? SILL_ROW : 0` exactly; the other styles put a window in the top row of a two-row storey, which is where a church window at two-metre cells belongs.

- [ ] **Step 4: Let a box door be a garage, and wire styles through the row generator**

In `app/models/game/building/row.rb`, in `validate!`'s `boxes.each` block, add:

```ruby
            raise Invalid, "a box door is true, false or \"garage\"" unless [ true, false, "garage" ].include?(box.door)
```

In `app/models/game/building/row_generator.rb`:

In `dwellings`, the four `Openings.new(...)` calls become styled — fronts and backs `Openings.new(seed: row.seed + i, style: :house)`, the two ends `Openings.new(seed: row.seed + 7, style: :annex)` and `Openings.new(seed: row.seed + 11, style: :annex)`. (The ends had no door before either: `edge` 1 and 3 are not the door edge. `:annex` keeps their windows every other column.)

In `boxes`, replace `openings = box.solid ? nil : Openings.new(seed: row.seed + 100 + i)` with:

```ruby
          style = style_for(row, box)
          openings = style ? Openings.new(seed: row.seed + 100 + i, style: style) : nil
```

and add, after `covered_to`:

```ruby
      # How a box is punctured, by what it is. A solid box -- a shed -- gets nothing; a
      # garage its door; a church's parts theirs, told apart by the roof the importer gave
      # them (a pyramid is a tower) and by which part carries the door (the nave); anything
      # else with a door is a house of its own, and anything without one an annex.
      def self.style_for(row, box)
        return nil if box.solid
        return :garage if box.door == "garage"

        if row.category == "church" || row.category == "hall"
          return :tower if box.roof == "pyramid"
          return box.door ? :nave : :chapel
        end
        box.door ? :house : :annex
      end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/models/game/building/row_test.rb test/models/game/building/generator_test.rb`
Expected: PASS, including the worked examples (`840`, `921`, `1553` and every offset) unchanged.

If `"a church's parts are punctured by what they are"` fails on the tower's per-storey count, read which face and storey: the tower's faces are 6 m at 2 m cells = 3 columns, so `:one` gives the middle column, one window per face per storey.

- [ ] **Step 6: Run the model suite and commit**

Run: `bin/rails test`
Expected: PASS. `world_summary_test` proves no fixture's `piece_count` moved — patches are not pieces.

```bash
git add app/models/game/building/openings.rb app/models/game/building/row.rb app/models/game/building/row_generator.rb test/models/game/building/row_test.rb
git commit -m "Give openings a style: a door the size of a door, a garage door, a church's rhythm

A dwelling's front is a one-cell door with a two-cell window beside it; three metres
of door is a garage, and a box may say so. A nave, a tower and a chapel are punctured
by what they are. Styles change patches and never grids, so nothing renumbers, and
the classic style is byte for byte what the hand-made worlds were built from.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Hedges are pieces, lawns are pictures

**Files:**
- Create: `app/models/game/building/gardens.rb`
- Modify: `app/models/game/building/row.rb` (gardens)
- Modify: `app/models/game/building/row_generator.rb` (step 7, `lawns`)
- Modify: `app/models/game/building/generator.rb` (`lawns`)
- Modify: `app/models/game/building/surface.rb` (`KINDS`)
- Modify: `app/models/game/building/rubble.rb` (`volumes_by_material`)
- Modify: `app/models/game/damage/collapse.rb` (`each_cell`)
- Modify: `app/models/world_object.rb` (`lawns`)
- Test: `test/models/game/building/row_test.rb`, `test/models/game/damage/collapse_test.rb`, `test/models/world_object_test.rb`

**Interfaces:**
- Consumes: `Openings#door_columns(cols)` (Task 3), `Materials.fetch(:hedge)` (Task 1).
- Produces: `Row#gardens` → Array of `Row::Garden` (`bay` Integer, `depth` Float, metres from the row's front line to the road edge); recipe key `"gardens": [ { "bay": 0, "depth": 5.4 }, … ]`. `Gardens.hedges(row)` → Array of `Surface` (`kind: :hedge`, `storey: -1`, one row of cells, `bay`). `Gardens.lawns(row)` → Array of rings `[[x, z] × 4]` in the row frame. `RowGenerator.lawns(row)` → the same rings rotated by `yaw`. `Generator.lawns(recipe)` → rings or `[]`. `WorldObject#to_building` gains `lawns:` (omitted when empty). Constants `Gardens::HEDGE_HEIGHT = 1.0`, `HEDGE_THICKNESS = 0.5`, `KERB = 0.4`, `PATH = 1.2`, `BACK = 5.0`.

- [ ] **Step 1: Write the failing tests**

Append to `test/models/game/building/row_test.rb` inside the class:

```ruby
  def gardened(**overrides)
    pair(**{ "gardens" => [ { "bay" => 0, "depth" => 5.0 }, { "bay" => 1, "depth" => 5.0 } ] }.merge(overrides))
  end

  # STEP 7 OF THE CONTRACT. A hedge is one row of cells per garden, after the boxes and
  # before the rubble, so a row that gains a garden keeps every index it had and the rubble
  # moves back by the hedge -- 6 cells per 6 m dwelling here.
  test "hedges come after the boxes and before the rubble, one per garden" do
    set = gardened

    assert_equal 31, set.surfaces.length
    assert_equal 852, set.piece_count
    assert_equal %i[hedge hedge rubble], set.surfaces.last(3).map(&:kind)
    assert_equal [ 768, 774, 780 ], set.surfaces.last(3).map(&:piece_offset)
    hedges = set.surfaces.select { |s| s.kind == :hedge }
    assert_equal [ 0, 1 ], hedges.map(&:bay)
    assert_equal [ -1, -1 ], hedges.map(&:storey), "a hedge stands outside every storey the collapse rule can reach"
    assert_equal [ 6, 6 ], hedges.map(&:cols)
    assert_equal [ 1, 1 ], hedges.map(&:rows)
    assert_equal :hedge, hedges.first.material.name
    # The front line is z = 0, the road edge 5 m out; the hedge stands KERB in from it,
    # its thickness straddling its plane, on the ground.
    assert_in_delta(-5.0 + 0.4 + 0.25, hedges.first.origin.z, 1e-9)
    assert_in_delta 0.0, hedges.first.origin.y, 1e-9
    assert_equal [ 0.0, 6.0 ], hedges.map { |h| h.origin.x }
  end

  test "a hedge is broken at the garden path, which meets the door" do
    set = gardened
    hedge = set.surfaces.find { |s| s.kind == :hedge }
    front = set.surfaces.first
    door = front.patches.find { |p| p.material == :door }
    void = hedge.patches.select { |p| p.material == :void }.map(&:col0).sort

    assert_equal 2, void.length, "a 1.2 m path is two one-metre cells"
    assert_includes void, door.col0, "the path meets the door"
    assert void.each_cons(2).all? { |a, b| b == a + 1 }, "the path is one gap, not two"
  end

  test "a row with no gardens has no hedges and moves nothing" do
    assert_equal 840, pair.piece_count
    assert_empty pair.surfaces.select { |s| s.kind == :hedge }
    assert_empty Game::Building::RowGenerator.lawns(Game::Building::Row.from(pair_recipe))
  end

  test "the wreckage of a house is not made of leaves" do
    rubble = gardened.surfaces.last

    refute_includes rubble.mix.map(&:first), :hedge
    assert_equal pair.surfaces.last.mix, rubble.mix, "a garden changes nothing about what the house is made of"
    assert_in_delta pair.surfaces.last.thickness, rubble.thickness, 1e-9, "nor how deep its wreckage lies"
  end

  # Two rectangles per front garden either side of the path, and one strip behind the row.
  test "lawns are the front garden minus the path, and a strip behind" do
    row = Game::Building::Row.from(pair_recipe("gardens" => [ { "bay" => 0, "depth" => 5.0 }, { "bay" => 1, "depth" => 5.0 } ]))
    lawns = Game::Building::Gardens.lawns(row)

    assert_equal 5, lawns.length
    fronts = lawns.first(4)
    fronts.each do |ring|
      assert_equal 4, ring.length
      assert_equal [ -5.0, 0.0 ], [ ring.map(&:last).min, ring.map(&:last).max ], "a front lawn runs from the road edge to the front line"
    end
    assert_in_delta 12.0 - 2 * 2.0, fronts.sum { |ring| ring.map(&:first).max - ring.map(&:first).min }, 1e-9,
                    "the two paths are the only gaps"
    back = lawns.last
    assert_equal [ 9.0, 14.0 ], [ back.map(&:last).min, back.map(&:last).max ], "five metres behind the footprint"
    assert_equal [ 0.0, 12.0 ], [ back.map(&:first).min, back.map(&:first).max ]
  end

  test "lawns turn with the row" do
    recipe = pair_recipe("yaw" => Math::PI / 2, "gardens" => [ { "bay" => 0, "depth" => 5.0 } ])
    flat = Game::Building::Gardens.lawns(Game::Building::Row.from(recipe.merge("yaw" => 0.0)))
    turned = Game::Building::RowGenerator.lawns(Game::Building::Row.from(recipe))

    assert_equal flat.length, turned.length
    fx, fz = flat.first.first
    tx, tz = turned.first.first
    assert_in_delta(-fz, tx, 1e-9)
    assert_in_delta fx, tz, 1e-9
    assert_equal turned, Game::Building::Generator.lawns(recipe)
    assert_empty Game::Building::Generator.lawns(footprint: [ [ 0, 0 ], [ 12, 0 ], [ 12, 15 ], [ 0, 15 ] ], storeys: 2, cell: 1.0, seed: 7)
  end

  test "a garden must front a dwelling and reach the road" do
    assert_raises(Game::Building::Row::Invalid) { pair("gardens" => [ { "bay" => 2, "depth" => 5.0 } ]) }
    assert_raises(Game::Building::Row::Invalid) { pair("gardens" => [ { "bay" => 0, "depth" => 0.0 } ]) }
  end
```

Append to `test/models/game/damage/collapse_test.rb` inside the class (use the file's existing helpers for a row recipe; if it builds rows through `Game::Building::Generator.call(hash)`, do the same):

```ruby
  # A hedge stands at storey -1, is skipped by name, and holds nothing up: three defences
  # against a collapse weighing a garden or felling one. Its cells appear in neither the
  # support nor the load nor the pieces that fall.
  test "a hedge neither holds a house up nor falls with it" do
    recipe = {
      "kind" => "row", "category" => "house", "pands" => %w[000001 000002], "yaw" => 0.0, "cell" => 1.0, "seed" => 1,
      "band" => [ 0.0, 9.0 ], "storeys" => 2, "storey_height" => 3.0, "eaves" => 6.0, "ridge" => 8.5, "roof" => "gable",
      "dwellings" => [ { "x0" => 0.0, "x1" => 6.0 }, { "x0" => 6.0, "x1" => 12.0 } ], "boxes" => [],
      "footprint" => [ [ 0, 0 ], [ 12, 0 ], [ 12, 9 ], [ 0, 9 ] ]
    }
    bare = Game::Building::Generator.call(recipe)
    gardened = Game::Building::Generator.call(recipe.merge("gardens" => [ { "bay" => 0, "depth" => 5.0 }, { "bay" => 1, "depth" => 5.0 } ]))
    hedge_indices = gardened.surfaces.select { |s| s.kind == :hedge }.flat_map { |s| (s.piece_offset...(s.piece_offset + s.piece_count)).to_a }
    # Every storey-0 wall of bay 0 that is not shared, in both buildings the same indices.
    walls = bare.surfaces.select { |s| s.kind == :wall && s.storey.zero? && s.bay.zero? && !s.shared? }
    broken = walls.flat_map { |s| (s.piece_offset...(s.piece_offset + s.piece_count)).to_a }

    before = Game::Damage::Collapse.evaluate(surfaces: bare, broken: broken, rules: rules)
    after = Game::Damage::Collapse.evaluate(surfaces: gardened, broken: broken, rules: rules)

    assert_equal before.collapsed, after.collapsed, "a garden changed whether the house stands"
    assert_equal({ 0 => 0 }, after.collapsed)
    assert_empty after.broken & hedge_indices, "the collapse felled the hedge"
    assert_equal before.broken.sort, after.broken.sort, "the collapse broke different pieces because of a garden"
  end
```

(`rules` is whatever helper the file already uses to build the collapse rules hash — read the file; it is `Game::Spec.default_rules[:collapse]` or a `rules(**overrides)` helper.)

Append to `test/models/world_object_test.rb`:

```ruby
  test "a hand-made building has no lawns and ships none" do
    refute world_objects(:targets_house).to_building.key?(:lawns)
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/models/game/building/row_test.rb test/models/game/damage/collapse_test.rb test/models/world_object_test.rb`
Expected: FAIL — `gardened` builds 29 surfaces (gardens ignored), `NameError: Gardens`, `Generator.lawns` undefined.

- [ ] **Step 3: Teach `Row` about gardens and `Surface` about hedges**

In `app/models/game/building/surface.rb`, change `KINDS`:

```ruby
      KINDS = %i[wall partition floor roof gable hedge rubble].freeze
```

In `app/models/game/building/row.rb`, add after `Box`:

```ruby
      # A front garden: the dwelling it fronts, and how far the lawn runs from the row's
      # front line to the road's edge. Written by the importer from the roads, never
      # guessed here.
      Garden = Struct.new(:bay, :depth, keyword_init: true)
```

Add `:gardens` to the `attr_reader`; in `from`, `gardens: Array(a["gardens"]).map { |g| g = g.transform_keys(&:to_s); Garden.new(bay: g.fetch("bay").to_i, depth: g.fetch("depth").to_f) }`; add `gardens:` to `initialize` (default `[]`) and its assignment; and in `validate!`:

```ruby
          gardens.each do |garden|
            raise Invalid, "a garden must front a dwelling" unless garden.bay.between?(0, dwellings.length - 1)
            raise Invalid, "a garden must reach the road" unless garden.depth.positive?
          end
```

- [ ] **Step 4: Write `Gardens`**

Create `app/models/game/building/gardens.rb`:

```ruby
module Game
  module Building
    # What stands between a dwelling and its street: a hedge along the road's edge, broken
    # at the garden path, and the lawn either side of the path.
    #
    # THE HEDGE IS PIECES. A hedge you cannot drive through is the one thing this game must
    # not have, and a piece is the only thing here that breaks, persists, and reveals to
    # every player alike. One surface per garden, one row of cells, the path's columns void
    # -- index space kept, geometry culled, exactly as a doorway is. It stands at storey -1
    # like rubble, so no collapse can weigh it or fell it, and it is left out of the
    # rubble's mix, because the wreckage of a house is not made of leaves.
    #
    # THE LAWN IS A PICTURE: rectangles the client drapes on the ground beside the road
    # ribbons, in the same mesh. Nothing about it is a piece, nothing about it crosses the
    # wire beyond these coordinates.
    module Gardens
      HEDGE_HEIGHT = 1.0
      HEDGE_THICKNESS = 0.5
      # How far in from the road's edge the hedge stands, and how wide the path from the
      # road to the door is. The path is whole cells, rounded up, because the hedge is cells.
      KERB = 0.4
      PATH = 1.2
      # The strip of lawn behind the footprint. A fixed depth for now; the BGT land cover is
      # the honest source and is the next pass.
      BACK = 5.0
      EAST = Vector3.new(1, 0, 0)
      UP = Vector3.new(0, 1, 0)

      # 7. One hedge per garden, in the order the gardens are listed.
      def self.hedges(row)
        row.gardens.map do |garden|
          d = row.dwellings.fetch(garden.bay)
          cols = Walls.cells(d.width, row.cell)
          Surface.new(
            kind: :hedge, storey: -1, material: Materials.fetch(:hedge),
            origin: Vector3.new(d.x0, 0.0, hedge_z(row, garden)), u: EAST, v: UP,
            width: d.width, height: HEDGE_HEIGHT, cols: cols, rows: 1, thickness: HEDGE_THICKNESS,
            patches: path_columns(row, garden.bay, cols).map { |c| Surface::Patch.new(col0: c, row0: 0, col1: c, row1: 0, material: :void) },
            seed: row.seed + 200 + garden.bay, bay: garden.bay
          )
        end
      end

      # The plane the hedge's thickness straddles: KERB in from the road's edge, then half
      # its own thickness, so its street face stands exactly KERB from the road.
      def self.hedge_z(row, garden)
        row.z0 - garden.depth + KERB + HEDGE_THICKNESS / 2.0
      end

      # The path is the door's columns widened to PATH, extending away from the end the
      # door stands near. Asked of the very Openings object the front wall was punctured by,
      # which is how the path is guaranteed to meet the door.
      def self.path_columns(row, bay, cols)
        openings = Openings.new(seed: row.seed + bay, style: :house)
        door = openings.door_columns(cols)
        return [] if door.empty?

        cell = row.dwellings.fetch(bay).width / cols
        wanted = [ (PATH / cell).ceil, 1 ].max
        extra = wanted - door.length
        return door if extra <= 0

        columns = door.first < cols / 2 ? door + (door.last + 1..door.last + extra).to_a : (door.first - extra...door.first).to_a + door
        columns.select { |c| c.between?(0, cols - 1) }
      end

      # Rings in the row's own frame, closed, four points each: for each garden the lawn
      # either side of the path, then one strip behind the footprint. The client drapes
      # them on the ground. Empty for a row with no gardens.
      def self.lawns(row)
        return [] if row.gardens.empty?

        fronts = row.gardens.flat_map do |garden|
          d = row.dwellings.fetch(garden.bay)
          cols = Walls.cells(d.width, row.cell)
          cell = d.width / cols
          path = path_columns(row, garden.bay, cols)
          z0 = row.z0 - garden.depth
          z1 = row.z0
          if path.empty?
            [ rect(d.x0, z0, d.x1, z1) ]
          else
            px0 = d.x0 + path.min * cell
            px1 = d.x0 + (path.max + 1) * cell
            [ rect(d.x0, z0, px0, z1), rect(px1, z0, d.x1, z1) ].reject { |ring| ring.nil? }
          end
        end
        back_z = row.footprint.map(&:last).max
        fronts + [ rect(row.x0, back_z, row.x1, back_z + BACK) ]
      end

      def self.rect(x0, z0, x1, z1)
        return nil if x1 - x0 < 0.05

        [ [ x0, z0 ], [ x1, z0 ], [ x1, z1 ], [ x0, z1 ] ]
      end
    end
  end
end
```

- [ ] **Step 5: Append the hedges to the row, keep leaves out of the rubble, and out of the collapse**

In `app/models/game/building/row_generator.rb`:

`call` becomes

```ruby
      def self.call(row)
        row = Row.from(row) unless row.is_a?(Row)
        # 7. Hedges after the boxes: a row that gains a garden keeps every index it had.
        built = dwellings(row) + boxes(row) + Gardens.hedges(row)
        surfaces = built + rubble(row, built)
        SurfaceSet.new(surfaces.map { |s| s.rotated(row.yaw) }, storey_count: row.storeys)
      end

      # The lawns, turned by the row's yaw exactly as its surfaces are, so the client can add
      # the building's position to them as it does to every surface origin.
      def self.lawns(row)
        row = Row.from(row) unless row.is_a?(Row)
        c = Math.cos(row.yaw)
        s = Math.sin(row.yaw)
        Gardens.lawns(row).map { |ring| ring.map { |x, z| [ (x * c - z * s).round(3), (x * s + z * c).round(3) ] } }
      end
```

Update the header comment's list of steps: `1 fronts and backs, 2 ends, 3 party walls, 4 interiors, 5 roof sections, 6 boxes, 7 hedges, then rubble LAST`.

In `app/models/game/building/generator.rb`, add:

```ruby
      # The lawns of a row, or nothing: a picture the client drapes, never pieces.
      def self.lawns(recipe)
        row?(recipe) ? RowGenerator.lawns(recipe) : []
      end
```

In `app/models/game/building/rubble.rb`, `volumes_by_material`: change `next if surface.kind == :rubble` to

```ruby
          # Rubble, because a building's wreckage cannot be made of itself; hedges, because
          # the wreckage of a house is not made of leaves and a garden must not change how
          # deep it lies.
          next if %i[rubble hedge].include?(surface.kind)
```

In `app/models/game/damage/collapse.rb`, `each_cell`: change `next if surface.kind == :rubble` to

```ruby
              next if %i[rubble hedge].include?(surface.kind)
```

and extend the comment above it: "A hedge is the garden a house stands behind, at the same storey of -1 for the same reason: nothing a collapse does reaches it."

In `app/models/world_object.rb`, `to_building`: after `palette:` add

```ruby
      # Rings the client drapes as lawn, in the building's rotated frame like its surfaces;
      # nothing for a building without gardens, so the four worlds gain no key.
      lawns: Game::Building::Generator.lawns(recipe).presence
```

(`.compact` already drops the nil.)

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bin/rails test test/models/game/building/row_test.rb test/models/game/damage/collapse_test.rb test/models/world_object_test.rb test/models/game/building/generator_test.rb test/models/game/building/rubble_test.rb`
Expected: PASS. If `"hedges come after the boxes…"` reports 780 for the rubble offset but a different piece count, the rubble grid moved: it must not — `Rubble.build` is handed `rectangle_for_footprint(row)`, which reads the footprint, not the hedges.

- [ ] **Step 7: Run the model suite and commit**

Run: `bin/rails test`
Expected: PASS (no fixture carries `gardens` yet, so `world_summary_test`'s counts stand).

```bash
git add app/models/game/building/gardens.rb app/models/game/building/row.rb app/models/game/building/row_generator.rb app/models/game/building/generator.rb app/models/game/building/surface.rb app/models/game/building/rubble.rb app/models/game/damage/collapse.rb app/models/world_object.rb test/models/game/building/row_test.rb test/models/game/damage/collapse_test.rb test/models/world_object_test.rb
git commit -m "Put a hedge and a lawn in front of a dwelling: the hedge is pieces, the lawn a picture

A row's gardens become one hedge surface each -- kind hedge, storey -1, one row of
cells, the path void -- appended after the boxes and before the rubble, so nothing
renumbers. Leaves are kept out of the wreckage and out of the collapse rule by
storey, by name and by weight. Lawns are rings in the row's frame that the client
drapes on the ground.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: The importer picks a palette, finds the garages and lays out the gardens

**Files:**
- Modify: `app/models/game/import/rows.rb`
- Modify: `test/fixtures/{worlds,world_objects}/geleen.yml` (regenerated by `bin/rails geleen:import`)
- Test: `test/models/game/import/rows_test.rb`, `test/models/game/import/fixtures_test.rb`, `test/models/world_summary_test.rb`

**Interfaces:**
- Consumes: `Game::Palettes` (Task 2), `Row` gardens and `"garage"` (Tasks 3–4).
- Produces: recipe keys `palette` (String), `gardens` (Array), boxes with `door: "garage"` and their ring rotated to start at the street-facing edge. `Rows::PALETTES` (Hash category → Array of palette names), `Rows.garage_ring(ring, front_z)` → rotated ring or nil, `Rows#nearest_road(gx, gz)` → `{ distance:, width:, point: [gx, gz] }` or nil. Constants `GARAGE_WIDTH = 2.5`, `GARDEN_MIN = 1.5`, `GARDEN_MAX = 25.0`.

- [ ] **Step 1: Write the failing tests**

Append to `test/models/game/import/rows_test.rb` inside the class:

```ruby
  test "every row carries a palette the table knows, and the estate is not one colour" do
    palettes = rows.objects.map { |o| o[:recipe]["palette"] }

    palettes.each { |key| assert Game::Palettes.key?(key), "#{key} is not a palette" }
    assert_operator palettes.uniq.length, :>, 1, "thirty rows in one colour is the estate we had"
    church = church_rows.objects.find { |o| o[:category] == "church" }
    assert_equal "church", church[:recipe]["palette"]
  end

  # Pure geometry, so it can be asked of rings that exist and rings that do not. The
  # street is at low z in the row frame; `front_z` is the row's front line.
  test "a street-facing box a car wide is a garage, and its street edge comes first" do
    garage = Game::Import::Rows.garage_ring([ [ 0, 3 ], [ 0, 0 ], [ 6, 0 ], [ 6, 3 ] ], 0.0)
    assert_equal [ [ 0, 0 ], [ 6, 0 ], [ 6, 3 ], [ 0, 3 ] ], garage, "rotated so the edge along the street is first"
    assert_equal [ [ 0, 0 ], [ 6, 0 ], [ 6, 3 ], [ 0, 3 ] ], Game::Import::Rows.garage_ring([ [ 0, 0 ], [ 6, 0 ], [ 6, 3 ], [ 0, 3 ] ], 0.0)
    assert_nil Game::Import::Rows.garage_ring([ [ 0, 5 ], [ 6, 5 ], [ 6, 8 ], [ 0, 8 ] ], 0.0), "behind the front line is a shed"
    assert_nil Game::Import::Rows.garage_ring([ [ 0, 0 ], [ 2, 0 ], [ 2, 3 ], [ 0, 3 ] ], 0.0), "two metres is not a car"
    assert_nil Game::Import::Rows.garage_ring([ [ 0, 0 ], [ 0, 6 ], [ 2, 6 ], [ 2, 0 ] ], 0.0), "a box deeper than it is wide, two metres across, is a shed"
  end

  test "a garage box carries its door and every garage is one storey" do
    garages = (rows.objects + church_rows.objects).flat_map { |o| o[:recipe]["boxes"].select { |b| b["door"] == "garage" } }
    garages.each do |box|
      assert_equal 1, box["storeys"]
      refute box["solid"]
    end
  end

  test "dwellings facing a road get a front garden that reaches it" do
    houses = rows.objects.select { |o| o[:category] == "house" }
    gardens = houses.flat_map { |o| o[:recipe]["gardens"] }
    dwellings = houses.sum { |o| o[:recipe]["dwellings"].length }

    assert_operator gardens.length, :>=, dwellings / 2, "fewer than half the estate's dwellings have a garden"
    gardens.each do |g|
      assert_operator g["depth"], :>=, Game::Import::Rows::GARDEN_MIN
      assert_operator g["depth"], :<=, Game::Import::Rows::GARDEN_MAX
    end
    houses.each do |o|
      bays = o[:recipe]["gardens"].map { |g| g["bay"] }
      assert_equal bays.uniq, bays, "#{o[:name]} gives one dwelling two gardens"
      bays.each { |b| assert_operator b, :<, o[:recipe]["dwellings"].length }
    end
    # The row this file already proves faces its road has a garden.
    row12 = rows.objects.find { |o| o[:recipe]["pands"].include?("053076") }
    assert_operator row12[:recipe]["gardens"].length, :>=, 1, "the row that faces its road has no garden"
  end

  test "a garden never lies under a box of its own bay" do
    (rows.objects + church_rows.objects).each do |o|
      z0 = o[:recipe]["band"]&.first
      Array(o[:recipe]["gardens"]).each do |g|
        o[:recipe]["boxes"].select { |b| b["bay"] == g["bay"] }.each do |box|
          assert_operator box["ring"].map(&:last).min, :>=, z0 - 0.3, "#{o[:name]}: #{box['name']} stands in bay #{g['bay']}'s garden"
        end
      end
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/models/game/import/rows_test.rb`
Expected: FAIL — `palette` nil, `garage_ring` undefined, `gardens` nil.

- [ ] **Step 3: Palette, garages and gardens in `Rows`**

In `app/models/game/import/rows.rb`:

Add constants after `PER_PART`:

```ruby
      # Which colours a row may be drawn in, by category, drawn by the row's seed. This
      # estate is 1987 brown-and-red brick under anthracite or orange tiles; the church is
      # the church.
      PALETTES = {
        "house" => %w[brown_brick red_brick brown_brick sand_brick dark_brick red_brick],
        "apartments" => %w[brown_brick sand_brick dark_brick],
        "shed" => %w[brown_brick dark_brick],
        "church" => %w[church],
        "hall" => %w[church dark_brick]
      }.freeze
      # A box is a garage when its street-facing edge is at least a car wide.
      GARAGE_WIDTH = 2.5
      # How deep a front garden may be, from the front line to the road's edge. Shallower
      # is a pavement; deeper is not this dwelling's garden.
      GARDEN_MIN = 1.5
      GARDEN_MAX = 25.0
```

Change the roads kept in `initialize` to carry their widths:

```ruby
        @roads = roads.map { |r| [ Array(r["points"]), (r["width"] || 5.5).to_f ] }.select { |pts, _| pts.length >= 2 }
```

and `road_distance` to read the points out of the pair:

```ruby
      def road_distance(gx, gz)
        nearest_road(gx, gz).fetch(:distance)
      end

      # The nearest road to a point, its width, and the point on it that is nearest.
      def nearest_road(gx, gz)
        best = nil
        @roads.each do |points, width|
          points.each_cons(2) do |(x1, z1), (x2, z2)|
            px, pz = nearest_on_segment(gx, gz, x1, z1, x2, z2)
            distance = Math.hypot(gx - px, gz - pz)
            best = { distance: distance, width: width, point: [ px, pz ] } if best.nil? || distance < best[:distance]
          end
        end
        best
      end
```

Add beside `segment_distance` (keep `segment_distance` for anything else that calls it):

```ruby
        def nearest_on_segment(px, pz, x1, z1, x2, z2)
          dx, dz = x2 - x1, z2 - z1
          length2 = dx * dx + dz * dz
          t = length2.zero? ? 0.0 : (((px - x1) * dx + (pz - z1) * dz) / length2).clamp(0.0, 1.0)
          [ x1 + t * dx, z1 + t * dz ]
        end
```

Add the pure garage rule as a class method (public, tested directly):

```ruby
      # The edge of a box that faces the street, or nil: it runs along the row (more x than
      # z), is at least a car wide, and stands no further back than the row's front line.
      # The street is at low z in the row frame. Returns the ring rotated to start at that
      # edge, because the generator puts a box's door on its first edge.
      def self.garage_ring(ring, front_z)
        candidates = ring.each_with_index.filter_map do |a, i|
          b = ring[(i + 1) % ring.length]
          next unless (b[0] - a[0]).abs > (b[1] - a[1]).abs
          next unless Math.hypot(b[0] - a[0], b[1] - a[1]) >= GARAGE_WIDTH
          next unless (a[1] + b[1]) / 2.0 <= front_z + 0.5

          [ (a[1] + b[1]) / 2.0, i ]
        end
        return nil if candidates.empty?

        ring.rotate(candidates.min.last)
      end
```

In `build`, right after `recipe = { … }` is created, add the palette:

```ruby
          choices = PALETTES.fetch(category, %w[brown_brick])
          recipe["palette"] = choices[seed % choices.length]
```

In the `houses` branch, in the `annexes.each do |p|` loop, replace the `recipe["boxes"] <<` with:

```ruby
              ring = local.call(p, "simple").map { |x, z| [ x.round(2), z.round(2) ] }
              door = false
              # A one-storey annex whose street edge is a car wide is a garage, and its
              # ring is turned so that edge is the one the generator puts the door on.
              if %w[house apartments].include?(category) && (garage = self.class.garage_ring(ring, band_z0))
                ring = garage
                door = "garage"
              end
              recipe["boxes"] << { "ring" => ring, "eaves" => part_height(p).round(2), "ridge" => part_height(p).round(2), "storeys" => 1,
                                   "roof" => "flat", "door" => door, "solid" => false, "bay" => bay_of(recipe["dwellings"], ring), "name" => p["source_id"][-8..] }
```

and after that loop (still inside `if houses`), add the gardens:

```ruby
            # A front garden per dwelling that faces a road: the strip from the front line to
            # the road's edge, when the nearest road lies across the front -- in front of the
            # dwelling rather than beside or behind it -- and no box of this bay stands in it.
            recipe["gardens"] = recipe["dwellings"].each_with_index.filter_map do |d, i|
              mx = (d["x0"] + d["x1"]) / 2.0
              road = nearest_road(*frame.to_world(mx, band_z0))
              next unless road

              lx, lz = frame.to_local(*road[:point])
              depth = road[:distance] - road[:width] / 2.0
              next unless lz < band_z0 - 1.0 && (lx - mx).abs < (d["x1"] - d["x0"]) && depth.between?(GARDEN_MIN, GARDEN_MAX)
              next if recipe["boxes"].any? { |b| b["bay"] == i && b["ring"].map(&:last).min < band_z0 - 0.3 }

              { "bay" => i, "depth" => depth.round(2) }
            end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/models/game/import/rows_test.rb`
Expected: PASS. If `"dwellings facing a road get a front garden"` fails on the count, print the depths the rule saw for the estate rows (`rows.objects.map { |o| [o[:name], o[:recipe]["gardens"]] }`) and check the road widths in `test/fixtures/files/geleen/roads.json` — the rule is right when the estate's front rows get a garden of a few metres and its rear rows none; adjust `GARDEN_MAX`, never the ≥ half assertion.

- [ ] **Step 5: Re-import the fixtures and re-seed the development database**

```bash
bin/rails geleen:import
```

Expected: `wrote test/fixtures/worlds/geleen.yml`, `wrote test/fixtures/world_objects/geleen.yml`, `wrote test/fixtures/terrain_tiles/geleen.yml`, `48 buildings, 9 tiles, 266 roads`. Then check what moved:

```bash
git diff --stat test/fixtures
git diff test/fixtures/world_objects/geleen.yml | grep -c "^+.*door: garage"
git diff test/fixtures/world_objects/geleen.yml | grep -c "^+    palette:"
```

Expected: `terrain_tiles/geleen.yml` unchanged; `worlds/geleen.yml` changes only its `content_digest`; every object row gains `palette:` (48), house rows gain `gardens:`, several gain a `door: garage` box, and `piece_count` grows by the hedge cells on rows with gardens. Record the garage count and the total pieces in your report.

```bash
bin/rails geleen:seed
```

Expected: `geleen: 48 objects, 9 tiles`. NEVER `db:seed`.

- [ ] **Step 6: Run the model suite, then the two system files that drive the imported world**

Run: `bin/rails test`
Expected: PASS — `world_summary_test` proves every regenerated `piece_count` matches, `fixtures_test` loads the new files.

Run: `bin/rails test test/system/geleen_test.rb test/system/bays_test.rb`
Expected: PASS. (Hedges are pieces on `LAYER.PROP`; a car at the spawn is on the road, not in a garden, so the drive test's clearance band holds. If the geleen drive test fails on clearance, look at whether a hedge stands across the spawn's path: `bin/rails runner 'puts World["geleen"].world_objects.where(kind: "building").map { |o| o.recipe["gardens"] }.inspect'`.)

- [ ] **Step 7: Commit**

```bash
git add app/models/game/import/rows.rb test/models/game/import/rows_test.rb test/fixtures/worlds/geleen.yml test/fixtures/world_objects/geleen.yml
git commit -m "Import a palette per row, a garage where a box faces the street, and a garden where a road does

The palette is drawn from the seed by category; a one-storey annex whose street edge
is a car wide is a garage with its ring turned to put the door on that edge; a
dwelling whose nearest road lies across its front gets a garden as deep as the strip
to the road's edge. Re-imported: every row carries a palette, the estate's front rows
their gardens, and piece_count moves by the hedges.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: The client paints the detail and colours by palette

**Files:**
- Create: `app/javascript/game/render/looks.js`
- Modify: `app/javascript/game/render/piece_meshes.js`
- Modify: `app/javascript/game/world/building.js`
- Modify: `app/javascript/game/world/buildings.js`
- Modify: `app/javascript/game/world/falling_pieces.js`
- Modify: `app/javascript/game/render/scene.js` (`QUALITY.textures` only; the sky is Task 7)
- Modify: `app/javascript/game/engine.js` (create `Looks`, hooks, disposal)
- Test: `test/system/looks_test.rb` (new), `test/system/building_test.rb` and `test/system/street_test.rb` (must stay green)

**Interfaces:**
- Consumes: `spec.materials[*].look`, `spec.materials[*].role`, `spec.palettes`, `spec.arena.buildings[*].palette`, `spec.rules.looks.jitter`.
- Produces: `Looks` (`new Looks(materials, quality, renderer)`, `has(name)`, `apply(material, name, { metres })`, `slabMaterial(name)`, `readout()`, `dispose()`), `TILE`, `SIZE`, `PATTERNS`. `PieceMeshes` constructor `(scene, materialSpecs, { looks } = {})`; `add(name, matrix, colour = WHITE, cellU = 0, cellV = 0)`; `cellUVAt(name, slot)` → `[u, v]`; `baseAt(name, slot, target)` → `Color`. `Building` constructor gains `palettes = {}, lookRules = {}`; `Building#tintFor(name, index, target)` → `Color`; `Building#cellUV(index)` → `[u, v]`; `Building#tint(index)` → `"#rrggbb"`. `FallingPieces` constructor gains `looks`; a slab shape may carry `tint` (a `Color`). Hooks `__arenaLooks()`, `__arenaCellUV(piece, id)`, `__arenaTint(piece, id)`. `QUALITY.high.textures = true`, `QUALITY.low.textures = false`.

- [ ] **Step 1: Write the failing system test**

Create `test/system/looks_test.rb`:

```ruby
require "application_system_test_case"

# How the world is DRAWN, asserted without reading pixels. The textures are painted at boot
# from the numbers in the spec, the texture coordinates run in metres along a surface, and
# the colours are a palette applied per instance -- each of which has a readout.
class LooksTest < ApplicationSystemTestCase
  def boot(world, quality:, match:, spawn: nil, time: nil)
    visit_world(world, quality: quality, match: match, spawn: spawn, time: time)
    wait_for(timeout: 90, message: "#{world} never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
  end

  def looks = page.evaluate_script("window.__arenaLooks()")

  # `high` is where the detail lives: a texture per patterned material, none for steel.
  test "at high quality every patterned material is painted and steel is not" do
    boot("targets", quality: "high", match: "looks-high")
    readout = looks

    assert readout["enabled"]
    assert_equal 2, readout["tile"], "one texture covers two metres of surface"
    %w[brick roof_tile timber glass plaster concrete].each { |name| assert_includes readout["textured"], name }
    refute_includes readout["textured"], "steel", "steel is flat and reflective"
    refute_includes readout["textured"], "rubble"
    assert_empty severe_console_errors
  end

  # `low` is what the suite is calibrated on and must keep today's flat materials.
  test "at low quality nothing is painted" do
    boot("targets", quality: "low", match: "looks-low")
    readout = looks

    refute readout["enabled"]
    assert_empty readout["textured"]
  end

  # The front wall of the targets house: surface 0, twelve one-metre columns, three rows.
  # cellUV is the cell's offset along its surface in metres, so the bond runs on across it.
  test "texture coordinates run in metres along a wall" do
    boot("targets", quality: "low", match: "looks-uv")
    building = page.evaluate_script("window.__arenaBuildingIds()[0]")
    uv = ->(piece) { page.evaluate_script("window.__arenaCellUV(arguments[0], arguments[1])", piece, building) }

    assert_in_delta 0.0, uv.call(0)[0], 1e-6
    assert_in_delta 0.0, uv.call(0)[1], 1e-6
    assert_in_delta 1.0, uv.call(1)[0], 1e-6, "one cell along is one metre along"
    assert_in_delta 0.0, uv.call(1)[1], 1e-6
    assert_in_delta 0.0, uv.call(12)[0], 1e-6, "the next row starts again"
    assert_in_delta 1.0, uv.call(12)[1], 1e-6, "one row up is one metre up"
  end

  # Two rows in two palettes: the same material comes out a different colour, and the
  # church is drawn in the church's.
  test "buildings are coloured by their palette" do
    boot("geleen", quality: "low", match: "looks-palette")
    wait_for(timeout: 60, message: "the world never stepped") { page.evaluate_script("window.__arena.steps").positive? }
    pair = page.evaluate_script(<<~JS)
      (() => {
        const ids = window.__arenaBuildingIds()
        const byPalette = new Map()
        for (const id of ids) {
          const spec = window.__arenaBuildingSpec(id)
          if (spec.category !== "house") continue
          const wall = spec.surfaces.find(s => s.kind === "wall" && s.mat === "brick")
          if (!wall) continue
          // The first plain-brick cell of the wall: not a patch.
          let piece = null
          for (let i = wall.off; i < wall.off + wall.cols * wall.rows; i++) {
            if (window.__arenaPieceState(i, id).material === "brick") { piece = i; break }
          }
          if (piece === null || byPalette.has(spec.palette)) continue
          byPalette.set(spec.palette, { id, piece, palette: spec.palette, tint: window.__arenaTint(piece, id) })
          if (byPalette.size === 2) break
        }
        return [ ...byPalette.values() ]
      })()
    JS

    assert_equal 2, pair.length, "the estate is drawn in one palette"
    refute_equal pair[0]["tint"], pair[1]["tint"], "#{pair[0]['palette']} and #{pair[1]['palette']} colour brick the same"
    pair.each { |p| assert_match(/\A#[0-9a-f]{6}\z/, p["tint"]) }
    church = page.evaluate_script("window.__arenaBuildingIds().map(i => window.__arenaBuildingSpec(i)).find(s => s.category === 'church').palette")
    assert_equal "church", church
  end
end
```

Read `__arenaPieceState` in `engine.js` (around line 225) to confirm the returned object carries `material`; if the key is named differently, use that name.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/system/looks_test.rb`
Expected: FAIL — `__arenaLooks is not a function`.

- [ ] **Step 3: Write `looks.js`**

Create `app/javascript/game/render/looks.js`:

```js
import * as THREE from "three"

// How a material is DRAWN: the brick bond, the tile courses, the planks, painted once at
// boot into textures from the numbers Ruby ships in `materials[*].look`. No image files,
// no downloads -- every pixel comes from the spec, the same on every machine.
//
// Textures rather than a pattern evaluated per fragment, for three reasons. A mortar line
// is a few millimetres wide: evaluated per fragment it aliases into shimmer at thirty
// metres unless filtered by hand, where a texture's mipmaps filter it for free. The normal
// map is the same picture, and a per-fragment pattern would need its own derivative
// machinery for the relief. And headless Chrome's software rasteriser runs the suite: a
// texture fetch is the cheapest thing a fragment can do.
//
// The albedo is painted in VALUE space -- light and nearly neutral -- because the colour
// is the palette's, applied per instance (PieceMeshes): tint = palette[role] x jitter x
// damage shade. One pool, one texture and one draw call serve every building whatever its
// palette.

// Metres of surface one texture covers, and texels per tile edge (a texel is 4 mm). Shape
// constants of the drawing, not tuning: everything that decides WHAT is drawn arrives in
// the spec. If the repetition ever shows on tiles or planks, the tile grows to 4 m at four
// times the memory.
export const TILE = 2
export const SIZE = 512
// Texels per metre.
const PX = SIZE / TILE
// Patterns this file paints. Ruby's Material::PATTERNS is the same list, and
// materials_test holds every material's look to it.
export const PATTERNS = [ "brick", "tiles", "planks", "plaster", "concrete", "glass", "leaves" ]

export class Looks {
  constructor(materials, quality, renderer = null) {
    this.materials = materials
    this.enabled = Boolean(quality.textures)
    this.anisotropy = renderer?.capabilities?.getMaxAnisotropy?.() ?? 1
    this.textures = new Map()
    this.lawnTexture = null
    if (!this.enabled) return

    for (const [ name, spec ] of Object.entries(materials)) {
      const look = spec.look
      if (!look || !PATTERNS.includes(look.pattern)) continue
      this.textures.set(name, paint(look, spec, this.anisotropy))
    }
  }

  has(name) {
    return this.textures.has(name)
  }

  // Dresses a MeshStandardMaterial in `name`'s look: colour white, because the tint rides
  // on the instance; the three maps; and, unless `metres` is off, the vertex chunk that
  // maps texture coordinates from metres along the surface rather than from the cube's
  // own uv. Glass keeps per-cell uv: its frame is drawn round each pane.
  apply(material, name, { metres = true } = {}) {
    const look = this.textures.get(name)
    if (!look) return material

    material.color.set("#ffffff")
    material.map = look.map
    material.normalMap = look.normalMap
    material.normalScale.set(look.relief, look.relief)
    material.roughnessMap = look.roughnessMap
    // The map carries the roughness; the scalar would multiply it a second time.
    material.roughness = 1
    if (look.alpha) {
      material.transparent = true
      material.opacity = 1
    }
    if (metres && look.metres) installMetresUv(material)
    material.needsUpdate = true
    return material
  }

  // A material for a slab of `name` falling on a mesh of its own: the look if there is
  // one, otherwise flat; DoubleSide because a slab is seen from every side as it tumbles.
  // Colour white here too -- the caller sets the tint the slab fell with.
  slabMaterial(name) {
    const spec = this.materials[name] || {}
    const material = new THREE.MeshStandardMaterial({
      color: "#ffffff", roughness: spec.roughness ?? 0.85, metalness: spec.metalness ?? 0.05,
      transparent: (spec.opacity ?? 1) < 1, opacity: spec.opacity ?? 1, side: THREE.DoubleSide
    })
    return this.apply(material, name)
  }

  // The lawn's texture, painted on first use: a leafy speckle with no relief. Null when
  // textures are off.
  lawn() {
    if (!this.enabled) return null
    if (!this.lawnTexture) {
      const albedo = canvas()
      leaves(albedo.getContext("2d"), null, null, { base: "#e2ead8", variation: 0.18 }, {})
      this.lawnTexture = texture(albedo, this.anisotropy)
      this.lawnTexture.colorSpace = THREE.SRGBColorSpace
    }
    return this.lawnTexture
  }

  readout() {
    return { enabled: this.enabled, tile: TILE, size: SIZE, textured: [ ...this.textures.keys() ].sort() }
  }

  dispose() {
    for (const look of this.textures.values()) {
      look.map.dispose()
      look.normalMap.dispose()
      look.roughnessMap.dispose()
    }
    this.textures.clear()
    this.lawnTexture?.dispose()
    this.lawnTexture = null
  }
}

// --- the shader chunk ----------------------------------------------------------------

// Texture coordinates in METRES along the surface, continuous across the cells of a wall.
//
// Each instance carries its cell's offset along its surface in metres (`cellUV`, written
// beside the instance matrix), and the instance matrix's column lengths are the cell's
// size -- cellMatrix composes T * R * S with scale (width, height, thickness), so the unit
// cube's local position in [-0.5, 0.5] becomes metres from the cell's corner. A face whose
// object-space normal is +-z is one of the wall's two faces: it maps (x, y) + cellUV, so
// the bond runs on into the neighbouring cell and the courses stay level along the row. A
// face whose normal is +-x or +-y is a cross-section exposed where a cell is missing: it
// maps the cell's own depth, so a hole shows brick ends rather than a stretched face.
//
// A plain Mesh (a falling slab) has no instanceMatrix and no cellUV: its scale comes off
// modelMatrix and the attribute reads WebGL's default of zero, so the slab keeps the bond
// it was cut with, starting from its own corner.
const METRES_UV = /* glsl */`
vec3 metresScale;
#ifdef USE_INSTANCING
  metresScale = vec3( length( instanceMatrix[ 0 ].xyz ), length( instanceMatrix[ 1 ].xyz ), length( instanceMatrix[ 2 ].xyz ) );
#else
  metresScale = vec3( length( modelMatrix[ 0 ].xyz ), length( modelMatrix[ 1 ].xyz ), length( modelMatrix[ 2 ].xyz ) );
#endif
vec3 metres3 = ( position + 0.5 ) * metresScale;
vec3 metresN = abs( normal );
vec2 metres;
if ( metresN.z >= metresN.x && metresN.z >= metresN.y ) metres = metres3.xy + cellUV;
else if ( metresN.x >= metresN.y ) metres = metres3.zy;
else metres = metres3.xz;
vec2 metresUv = metres / TILE_METRES;
#if defined( USE_UV ) || defined( USE_ANISOTROPY )
  vUv = metresUv;
#endif
#ifdef USE_MAP
  vMapUv = metresUv;
#endif
#ifdef USE_NORMALMAP
  vNormalMapUv = metresUv;
#endif
#ifdef USE_ROUGHNESSMAP
  vRoughnessMapUv = metresUv;
#endif
`

function installMetresUv(material) {
  material.onBeforeCompile = (shader) => {
    shader.vertexShader = `attribute vec2 cellUV;\n#define TILE_METRES ${TILE.toFixed(1)}\n` +
      shader.vertexShader.replace("#include <uv_vertex>", METRES_UV)
  }
  // Every material dressed this way compiles the same chunk, so they share programs
  // where their other defines agree.
  material.customProgramCacheKey = () => "metres-uv"
}

// --- painting --------------------------------------------------------------------------

function paint(look, spec, anisotropy) {
  const albedo = canvas()
  const height = canvas()
  const rough = canvas()
  PAINTERS[look.pattern](albedo.getContext("2d"), height.getContext("2d"), rough.getContext("2d"), look, spec)

  const map = texture(albedo, anisotropy)
  map.colorSpace = THREE.SRGBColorSpace
  return {
    map,
    normalMap: texture(normalFrom(height), anisotropy),
    roughnessMap: texture(rough, anisotropy),
    relief: look.relief ?? 0,
    alpha: look.pattern === "glass",
    // Glass maps per cell -- its frame goes round each pane -- everything else in metres.
    metres: look.pattern !== "glass"
  }
}

function canvas() {
  const element = document.createElement("canvas")
  element.width = SIZE
  element.height = SIZE
  return element
}

function texture(source, anisotropy) {
  const result = new THREE.CanvasTexture(source)
  result.wrapS = THREE.RepeatWrapping
  result.wrapT = THREE.RepeatWrapping
  result.anisotropy = anisotropy
  result.needsUpdate = true
  return result
}

// A CSS colour: `hex` with its lightness multiplied by `factor`.
function shade(hex, factor) {
  const value = parseInt(hex.slice(1), 16)
  const channel = (shift) => Math.max(0, Math.min(255, Math.round(((value >> shift) & 255) * factor)))
  return `rgb(${channel(16)}, ${channel(8)}, ${channel(0)})`
}

function grey(level) {
  const v = Math.max(0, Math.min(255, Math.round(level * 255)))
  return `rgb(${v}, ${v}, ${v})`
}

function fill(ctx, colour) {
  if (!ctx) return
  ctx.fillStyle = colour
  ctx.fillRect(0, 0, SIZE, SIZE)
}

function box(ctx, colour, x, y, w, h) {
  if (!ctx) return
  ctx.fillStyle = colour
  ctx.fillRect(x, y, w, h)
}

// Deterministic in [0, 1): the same texel on every machine, because two players have to
// see the same wall.
function noise(a, b, c = 0) {
  let h = (a * 374761393 + b * 668265263 + c * 2246822519) | 0
  h = Math.imul(h ^ (h >>> 13), 1274126177)
  return ((h ^ (h >>> 16)) >>> 0) / 4294967296
}

// Whole units per tile, so the texture repeats seamlessly: a 210 x 65 mm brick comes out
// 200 x 64.5 mm. Nobody measures.
function perTile(metres) {
  return Math.max(1, Math.round(TILE / metres))
}

// Running bond: courses of `unit[1]`, bricks of `unit[0]`, every other course offset by
// half a brick, joints recessed and darker, each brick its own lightness.
function brick(ctx, hctx, rctx, look, spec) {
  const courses = perTile(look.unit[1])
  const bricks = perTile(look.unit[0])
  const ch = SIZE / courses
  const bw = SIZE / bricks
  const joint = Math.max(1, look.joint * PX)
  fill(ctx, shade(look.base, look.joint_shade))
  fill(hctx, "#000000")
  fill(rctx, "#ffffff")
  for (let r = 0; r < courses; r += 1) {
    const offset = r % 2 === 0 ? 0 : bw / 2
    for (let c = -1; c <= bricks; c += 1) {
      const x = c * bw + offset + joint / 2
      const y = r * ch + joint / 2
      const w = bw - joint
      const h = ch - joint
      box(ctx, shade(look.base, 1 + (noise(r, c + 1, 0) - 0.5) * 2 * look.variation), x, y, w, h)
      box(hctx, grey(0.85 + 0.15 * noise(r, c + 1, 1)), x, y, w, h)
      box(rctx, grey(spec.roughness ?? 0.85), x, y, w, h)
    }
  }
}

// Overlapping courses: `unit[1]` tall, tiles `unit[0]` wide, offset half a tile per course.
// Each course's lower edge stands proud with a shadow line under it, which is the relief
// a tiled roof actually has.
function tiles(ctx, hctx, rctx, look, spec) {
  const courses = perTile(look.unit[1])
  const across = perTile(look.unit[0])
  const ch = SIZE / courses
  const tw = SIZE / across
  const joint = Math.max(1, look.joint * PX)
  const lip = Math.max(2, ch * 0.12)
  fill(ctx, shade(look.base, look.joint_shade))
  fill(hctx, "#000000")
  fill(rctx, grey(spec.roughness ?? 0.8))
  for (let r = 0; r < courses; r += 1) {
    const offset = r % 2 === 0 ? 0 : tw / 2
    for (let c = -1; c <= across; c += 1) {
      const x = c * tw + offset + joint / 2
      const y = r * ch
      const w = tw - joint
      const value = 1 + (noise(r, c + 1, 2) - 0.5) * 2 * look.variation
      box(ctx, shade(look.base, value), x, y, w, ch - lip)
      box(ctx, shade(look.base, value * look.joint_shade), x, y + ch - lip, w, lip)
      // Height rises down the course so the lower edge is the proud one.
      if (hctx) {
        const gradient = hctx.createLinearGradient(0, y, 0, y + ch - lip)
        gradient.addColorStop(0, grey(0.55))
        gradient.addColorStop(1, grey(1.0))
        hctx.fillStyle = gradient
        hctx.fillRect(x, y, w, ch - lip)
      }
    }
  }
}

// Boards `unit[0]` wide running up the surface's v axis -- up a door, along a deck -- with
// a dark seam between and a little grain along them.
function planks(ctx, hctx, rctx, look, spec) {
  const boards = perTile(look.unit[0])
  const bw = SIZE / boards
  const seam = Math.max(1, look.joint * PX)
  fill(ctx, shade(look.base, look.joint_shade))
  fill(hctx, "#000000")
  fill(rctx, grey(spec.roughness ?? 0.85))
  for (let b = 0; b < boards; b += 1) {
    const x = b * bw + seam / 2
    const value = 1 + (noise(b, 0, 3) - 0.5) * 2 * look.variation
    box(ctx, shade(look.base, value), x, 0, bw - seam, SIZE)
    box(hctx, grey(0.8 + 0.2 * noise(b, 1, 3)), x, 0, bw - seam, SIZE)
    for (let g = 0; g < 6; g += 1) {
      const gx = x + noise(b, g, 4) * (bw - seam)
      box(ctx, shade(look.base, value * (1 - look.variation * 0.4)), gx, 0, 1, SIZE)
    }
  }
}

// Flat with a little low-frequency mottling.
function plaster(ctx, hctx, rctx, look, spec) {
  fill(ctx, look.base)
  fill(hctx, grey(0.5))
  fill(rctx, grey(spec.roughness ?? 0.85))
  for (let i = 0; i < 40; i += 1) {
    const x = noise(i, 0, 5) * SIZE
    const y = noise(i, 1, 5) * SIZE
    const r = (0.15 + 0.35 * noise(i, 2, 5)) * PX
    const value = 1 + (noise(i, 3, 5) - 0.5) * 2 * look.variation
    blot(ctx, shade(look.base, value), x, y, r, 0.35)
  }
}

// Speckle and faint blotches, no relief to speak of.
function concrete(ctx, hctx, rctx, look, spec) {
  fill(ctx, look.base)
  fill(hctx, grey(0.5))
  fill(rctx, grey(spec.roughness ?? 0.95))
  for (let i = 0; i < 30; i += 1) {
    blot(ctx, shade(look.base, 1 + (noise(i, 3, 6) - 0.5) * look.variation), noise(i, 0, 6) * SIZE, noise(i, 1, 6) * SIZE, (0.2 + 0.5 * noise(i, 2, 6)) * PX, 0.3)
  }
  for (let i = 0; i < 6000; i += 1) {
    const x = noise(i, 0, 7) * SIZE
    const y = noise(i, 1, 7) * SIZE
    box(ctx, shade(look.base, 1 + (noise(i, 2, 7) - 0.5) * 2 * look.variation), x, y, 1 + noise(i, 3, 7), 1 + noise(i, 4, 7))
    box(hctx, grey(0.5 + (noise(i, 2, 7) - 0.5) * 0.3), x, y, 1, 1)
  }
}

// A transparent pane inside an opaque frame. `unit[0]` is the frame's width in metres of
// a one-metre cell; this texture maps per cell, so the frame goes round each pane.
function glass(ctx, hctx, rctx, look, spec) {
  const frame = Math.max(2, look.unit[0] * SIZE)
  ctx.clearRect(0, 0, SIZE, SIZE)
  fill(ctx, shade(look.base, 0.55))
  ctx.clearRect(frame, frame, SIZE - 2 * frame, SIZE - 2 * frame)
  const value = parseInt(look.base.slice(1), 16)
  ctx.fillStyle = `rgba(${(value >> 16) & 255}, ${(value >> 8) & 255}, ${value & 255}, 0.35)`
  ctx.fillRect(frame, frame, SIZE - 2 * frame, SIZE - 2 * frame)
  fill(hctx, "#ffffff")
  box(hctx, grey(0.7), frame, frame, SIZE - 2 * frame, SIZE - 2 * frame)
  fill(rctx, grey(0.6))
  box(rctx, grey(spec.roughness ?? 0.08), frame, frame, SIZE - 2 * frame, SIZE - 2 * frame)
}

// Leaves: a dense speckle of small lobes, light against dark, with relief from the same.
function leaves(ctx, hctx, rctx, look, spec) {
  fill(ctx, shade(look.base, 0.7))
  fill(hctx, grey(0.4))
  fill(rctx, grey(spec.roughness ?? 0.9))
  for (let i = 0; i < 2400; i += 1) {
    const x = noise(i, 0, 8) * SIZE
    const y = noise(i, 1, 8) * SIZE
    const r = (0.02 + 0.05 * noise(i, 2, 8)) * PX
    const value = 1 + (noise(i, 3, 8) - 0.5) * 2 * look.variation
    blot(ctx, shade(look.base, value), x, y, r, 1)
    blot(hctx, grey(0.4 + 0.6 * noise(i, 3, 8)), x, y, r, 1)
  }
}

// A soft disc, drawn again at the tile's edges so the wrap is seamless.
function blot(ctx, colour, x, y, r, alpha) {
  if (!ctx) return
  ctx.globalAlpha = alpha
  ctx.fillStyle = colour
  for (const dx of [ -SIZE, 0, SIZE ]) {
    for (const dy of [ -SIZE, 0, SIZE ]) {
      ctx.beginPath()
      ctx.ellipse(x + dx, y + dy, r, r * 0.7, noise(x | 0, y | 0, 9) * Math.PI, 0, Math.PI * 2)
      ctx.fill()
    }
  }
  ctx.globalAlpha = 1
}

const PAINTERS = { brick, tiles, planks, plaster, concrete, glass, leaves }

// A tangent-space normal map from a height canvas by central differences, wrapping at
// the edges so the tile stays seamless. Canvas y grows downward and texture v upward, so
// the green channel takes the gradient with its sign as canvas reads it.
function normalFrom(heightCanvas) {
  const ctx = heightCanvas.getContext("2d")
  const src = ctx.getImageData(0, 0, SIZE, SIZE).data
  const out = canvas()
  const octx = out.getContext("2d")
  const image = octx.createImageData(SIZE, SIZE)
  const strength = 3.0
  const h = (x, y) => src[(((y + SIZE) % SIZE) * SIZE + ((x + SIZE) % SIZE)) * 4] / 255

  for (let y = 0; y < SIZE; y += 1) {
    for (let x = 0; x < SIZE; x += 1) {
      const dx = h(x + 1, y) - h(x - 1, y)
      const dy = h(x, y + 1) - h(x, y - 1)
      let nx = -dx * strength
      let ny = dy * strength
      let nz = 1
      const length = Math.hypot(nx, ny, nz)
      nx /= length
      ny /= length
      nz /= length
      const i = (y * SIZE + x) * 4
      image.data[i] = Math.round((nx * 0.5 + 0.5) * 255)
      image.data[i + 1] = Math.round((ny * 0.5 + 0.5) * 255)
      image.data[i + 2] = Math.round((nz * 0.5 + 0.5) * 255)
      image.data[i + 3] = 255
    }
  }
  octx.putImageData(image, 0, 0)
  return out
}
```

Syntax check: `$(ls -d ~/.local/share/mise/installs/node/*/bin | head -1)/node --check app/javascript/game/render/looks.js`.

- [ ] **Step 4: Per-pool geometry with `cellUV`, white materials, a base tint per instance**

In `app/javascript/game/render/piece_meshes.js`:

Change the constructor and `allocate`:

```js
export class PieceMeshes {
  constructor(scene, materialSpecs, { looks = null } = {}) {
    this.scene = scene
    this.specs = materialSpecs
    this.looks = looks
    this.geometry = unitCube()
    this.pools = new Map()
    this.shapes = new Map()
  }
```

```js
  allocate(counts) {
    for (const [ name, count ] of counts) {
      if (count === 0) continue

      // Every pool owns a copy of its geometry, because a per-instance attribute lives on
      // the geometry and the pools do not share instance counts. A unit cube is 24
      // vertices; copying it a dozen times costs nothing.
      const geometry = (this.shapes.get(name) || this.geometry).clone()
      // Each instance's offset along its surface in metres, read by the metres shader
      // chunk (looks.js) so a brick bond runs on across the cells of a wall.
      geometry.setAttribute("cellUV", new THREE.InstancedBufferAttribute(new Float32Array(count * 2), 2))

      const mesh = new THREE.InstancedMesh(geometry, this.materialFor(name), count)
      mesh.name = `pieces:${name}`
      mesh.castShadow = true
      mesh.receiveShadow = true
      mesh.count = 0
      mesh.frustumCulled = false
      this.scene.add(mesh)
      // `base` is what each instance is coloured before damage: the palette's colour for
      // the material's role, with its jitter. Damage darkening multiplies it (tint), so it
      // has to be kept rather than read back off the instanceColor it has already dimmed.
      this.pools.set(name, { mesh, geometry, next: 0, live: 0, shown: new Uint8Array(count), base: new Float32Array(count * 3).fill(1) })
    }
  }
```

`materialFor` becomes:

```js
  // Colour WHITE, always: the instance carries the colour, which is how one pool serves
  // every palette. At high quality the material is dressed in the material's look --
  // albedo, normal and roughness maps painted at boot -- and at low it stays flat, so the
  // suite's timing assertions stand on the fragment cost they were measured at.
  materialFor(name) {
    const base = baseMaterial(name)
    const spec = this.specs[name] || this.specs[base] || {}
    const material = new THREE.MeshStandardMaterial({
      color: "#ffffff",
      roughness: spec.roughness ?? 0.85,
      metalness: spec.metalness ?? 0.05,
      transparent: (spec.opacity ?? 1) < 1,
      opacity: spec.opacity ?? 1,
      // See the note above unitCube: without this setColorAt does nothing at all.
      vertexColors: true
    })
    return this.looks ? this.looks.apply(material, base) : material
  }
```

`add` becomes:

```js
  // Returns the instance slot, which the caller keeps so it can hide the piece later.
  // `colour` is the piece's base tint; `cellU`/`cellV` its offset along its surface in
  // metres.
  add(name, matrix, colour = WHITE, cellU = 0, cellV = 0) {
    const pool = this.pools.get(name)
    if (!pool) return -1

    const slot = pool.next
    pool.next += 1
    pool.mesh.count = pool.next
    pool.mesh.setMatrixAt(slot, matrix)
    pool.base[slot * 3] = colour.r
    pool.base[slot * 3 + 1] = colour.g
    pool.base[slot * 3 + 2] = colour.b
    pool.mesh.setColorAt(slot, colour)
    pool.geometry.attributes.cellUV.setXY(slot, cellU, cellV)
    pool.shown[slot] = 1
    pool.live += 1
    pool.mesh.visible = true
    return slot
  }
```

`tint` becomes:

```js
  // Damage darkening, over the base tint. instanceColor multiplies the material's own,
  // and that multiplication happens in linear space.
  tint(name, slot, ratio) {
    const pool = this.pools.get(name)
    if (!pool || slot < 0) return

    const shade = 0.35 + 0.65 * Math.max(Math.min(ratio, 1), 0)
    pool.mesh.setColorAt(slot, SCRATCH_COLOUR.setRGB(pool.base[slot * 3] * shade, pool.base[slot * 3 + 1] * shade, pool.base[slot * 3 + 2] * shade))
    pool.mesh.instanceColor.needsUpdate = true
  }

  // Readouts for the tests: where an instance's texture starts and what it was coloured.
  cellUVAt(name, slot) {
    const pool = this.pools.get(name)
    if (!pool || slot < 0) return null
    const attribute = pool.geometry.attributes.cellUV
    return [ attribute.getX(slot), attribute.getY(slot) ]
  }

  baseAt(name, slot, target = SCRATCH_COLOUR) {
    const pool = this.pools.get(name)
    if (!pool || slot < 0) return null
    return target.setRGB(pool.base[slot * 3], pool.base[slot * 3 + 1], pool.base[slot * 3 + 2])
  }
```

In `finalise`, add `mesh.geometry.attributes.cellUV.needsUpdate = true` inside the loop. In `dispose`, add `geometry.dispose()` for each pool (destructure `{ mesh, geometry }`).

- [ ] **Step 5: The building writes its cells' offsets and colours**

In `app/javascript/game/world/building.js`:

Constructor: add `palettes = {}, lookRules = {}` to the destructured options, and after `this.rules = rules`:

```js
    // The building's colours: one key into the palette table, applied per instance where
    // damage darkening already lives. A recipe that names none is drawn in the default,
    // which is tuned to the colours the hand-made worlds always had.
    this.palette = palettes[spec.palette] || palettes.brown_brick || {}
    this.jitter = lookRules.jitter ?? 0
```

Add after `poolName`:

```js
  // What colour a piece of `name` starts out: the palette's colour for the material's role
  // -- brick for brick, roof_tile for tiles, door for a door -- or the material's own, and
  // a seeded jitter of a few percent so a wall is not one flat value. The albedo the pool
  // draws is value space, so this multiplication IS the colouring; damage darkening
  // multiplies it again (PieceMeshes#tint), and a broken cell is hidden, so the product is
  // never seen at zero.
  tintFor(name, index, target = TINT) {
    const spec = this.materials[name] || {}
    target.set((spec.role && this.palette[spec.role]) || spec.colour || "#888888")
    return target.multiplyScalar(1 + jitter(index, this.id) * this.jitter)
  }

  cellUV(index) {
    return this.meshes.cellUVAt(this.pool[index], this.slot[index])
  }

  tint(index) {
    const colour = this.meshes.baseAt(this.pool[index], this.slot[index])
    return colour ? `#${colour.getHexString()}` : null
  }
```

In `build`, replace `this.slot[index] = this.meshes.add(this.pool[index], matrix)` with:

```js
      // The cell's offset along its surface in metres, so the bond runs on from the cell
      // before it; and its colour.
      const cell = cellSize(surface)
      this.slot[index] = this.meshes.add(this.pool[index], matrix, this.tintFor(name, index), col * cell.width, row * cell.height)
```

and add `cellSize` to the import from `game/world/surface`. In `buildFragments`, replace `slots.push(this.meshes.add(pool, matrix))` with `slots.push(this.meshes.add(pool, matrix, this.tintFor(name, k)))` — the chunks in a red house's wreckage are red.

In `collapse`, right before `if (!this.falling.drop(matrix, slab.material, slab)) continue`, add:

```js
      // The colour it fell with, from its first cell, so a slab of a red house is red.
      slab.tint = this.tintFor(slab.material, slab.surface.off + slab.row * slab.surface.cols + slab.col, new THREE.Color())
```

At the bottom of the file, beside the other scratch objects:

```js
const TINT = new THREE.Color()

// A seeded value in [-1, 1) per cell, from the piece index and the building's own id so
// two buildings do not share a pattern of light and dark cells.
function jitter(index, salt) {
  let h = (index * 374761393 + salt * 668265263) | 0
  h = Math.imul(h ^ (h >>> 13), 1274126177)
  return (((h ^ (h >>> 16)) >>> 0) / 4294967296) * 2 - 1
}
```

- [ ] **Step 6: Wire `looks` and the palettes through, and tint the slabs**

In `app/javascript/game/world/buildings.js`: the constructor takes `looks = null`; `this.meshes = new PieceMeshes(scene, materials, { looks })`; `FallingPieces` gets `looks`; each `Building` gets `palettes: spec.palettes || {}, lookRules: spec.rules.looks || {}`.

In `app/javascript/game/world/falling_pieces.js`: take `looks = null` in the constructor and keep it as `this.looks`. In `take(name)`, build the mesh with `this.slabMaterial(name)`; in `drop`, replace `entry.mesh.material = this.debris.materialFor(name)` with:

```js
    // A slab keeps the look and the colour it fell with. The material is this entry's own
    // -- a slab's tint is per mesh -- and is remade only when the entry changes material,
    // because the textures under it are shared and a material is cheap.
    if (entry.name !== name || !entry.mesh.material.userData.slab) {
      entry.mesh.material.dispose()
      entry.mesh.material = this.slabMaterial(name)
    }
    entry.mesh.material.color.copy(shape.tint ?? WHITE)
```

Note `entry.name = name` is assigned a few lines above this in `drop`; move that assignment BELOW this block so the comparison sees the previous name. Add to the class:

```js
  slabMaterial(name) {
    const material = this.looks ? this.looks.slabMaterial(name) : this.debris.materialFor(name).clone()
    material.userData.slab = true
    return material
  }
```

and `const WHITE = new THREE.Color(1, 1, 1)` at the bottom. In `dispose`, dispose each entry's material (live and pooled).

In `app/javascript/game/render/scene.js`, add `textures` to both tiers:

```js
export const QUALITY = {
  high: { shadows: true, shadowMap: 2048, pixelRatio: 2, textures: true },
  low: { shadows: false, shadowMap: 512, pixelRatio: 1, textures: false }
}
```

In `app/javascript/game/engine.js`: import `Looks` from `game/render/looks`; after `this.renderer = createRenderer(...)`, add

```js
    // The textures every pool is dressed in, painted once from the spec. Nothing at `low`.
    this.looks = new Looks(this.spec.materials, this.quality, this.renderer)
```

pass `looks: this.looks` to `new Buildings({...})`; add the hooks beside `__arenaQuality`:

```js
    window.__arenaLooks = () => ({ ...this.looks.readout(), environment: Boolean(this.scene.environment), sky: this.timeName ?? null })
    window.__arenaCellUV = (piece, buildingId) => this.buildings?.find(buildingId)?.cellUV(piece) ?? null
    window.__arenaTint = (piece, buildingId) => this.buildings?.find(buildingId)?.tint(piece) ?? null
```

and in `dispose`, `this.looks?.dispose()` before `disposeScene`.

Syntax check every touched file with `node --check`.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `bin/rails test test/system/looks_test.rb`
Expected: PASS, all four. If `"at high quality…"` times out with a WebGL shader error in `severe_console_errors`, read the error: an undeclared `vMapUv` means a material got the chunk without a map (check `look.metres` gating); a redefinition of `cellUV` means the chunk was installed twice on one material.

Run: `bin/rails test test/system/building_test.rb test/system/street_test.rb`
Expected: PASS — the draw counts are unchanged, because pools are still one per material.

- [ ] **Step 8: Look at it, then commit**

Run `SHOTS=1 bin/rails test test/system/shots_test.rb -n test_photograph_the_house` and open `tmp/shots/02-wall-close.png` and `03-bond-raking.png`. The bond must run level across cells with no seam at cell edges, and the joints must read RECESSED. If they read raised, the normal map's green channel has the wrong sign: negate `ny` in `normalFrom` and re-shoot. Record what you saw in your report.

```bash
git add app/javascript/game/render/looks.js app/javascript/game/render/piece_meshes.js app/javascript/game/world/building.js app/javascript/game/world/buildings.js app/javascript/game/world/falling_pieces.js app/javascript/game/render/scene.js app/javascript/game/engine.js test/system/looks_test.rb
git commit -m "Paint bricks, tiles and planks at boot, and colour every building by its palette

Textures are painted once per patterned material from the numbers in the spec; each
instance carries its cell's offset in metres so a bond runs across a wall; colour is
palette x jitter x damage shade in the instance colour, so one pool and one draw
call still serve every building. Low quality stays flat.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Daylight, a sky, and something for steel to reflect

**Files:**
- Modify: `app/javascript/game/render/scene.js`
- Modify: `app/javascript/game/engine.js`
- Modify: `app/javascript/controllers/arena_controller.js`
- Modify: `test/application_system_test_case.rb` (`visit_world` gains `time:`)
- Test: `test/system/looks_test.rb`

**Interfaces:**
- Consumes: `spec.rules.sky.{day,night}` (Task 2), `QUALITY.textures` (Task 6).
- Produces: `createScene(quality, sky, renderer)` → `{ scene, sun }` with `scene.background` (a gradient texture at high, the horizon colour at low), `scene.fog`, and `scene.environment` at high; `skyTexture(sky)`. Engine option `time` (`"day"` default, `"night"`), `this.timeName`, `this.sunOffset`. `__arenaLooks().sky` and `.environment`.

- [ ] **Step 1: Write the failing tests**

Append to `test/system/looks_test.rb` inside the class:

```ruby
  # Daylight by default, so brick and tile detail has light to read in; the night the game
  # was lit for is one URL parameter away, because it was a deliberate look.
  test "the day is lit by default and the night is a parameter away" do
    boot("targets", quality: "high", match: "looks-day")
    assert_equal "day", looks["sky"]
    assert looks["environment"], "steel has nothing to reflect"

    boot("targets", quality: "high", match: "looks-night", time: "night")
    assert_equal "night", looks["sky"]

    boot("targets", quality: "low", match: "looks-low-sky")
    assert_equal "day", looks["sky"]
    refute looks["environment"], "low quality computes no environment map"
  end
```

In `test/application_system_test_case.rb`, `visit_world` gains `time: nil` and passes `time: time` into the params hash (the `.compact` drops it when nil).

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/system/looks_test.rb -n test_the_day_is_lit_by_default_and_the_night_is_a_parameter_away`
Expected: FAIL — `sky` is nil.

- [ ] **Step 3: Build the scene from the sky rules**

In `app/javascript/game/render/scene.js`, remove `const SKY = "#0e1116"` and replace `createScene` with:

```js
// The world is lit by `sky` -- one of rules.sky's entries, day or night, chosen by the URL.
// At high quality the sky is a gradient texture drawn behind everything and filtered into
// an environment map, so steel reflects a horizon and glass gets a highlight; at low it
// is the horizon colour and nothing more, so the suite's fragment cost is what it was.
export function createScene(quality, sky, renderer = null) {
  const scene = new THREE.Scene()
  const horizon = new THREE.Color(sky.horizon)
  scene.fog = new THREE.Fog(horizon, sky.fog[0], sky.fog[1])

  if (quality.textures && renderer) {
    const gradient = skyTexture(sky)
    scene.background = gradient
    const pmrem = new THREE.PMREMGenerator(renderer)
    scene.environment = pmrem.fromEquirectangular(gradient).texture
    pmrem.dispose()
  } else {
    scene.background = horizon
  }

  const [ skyColour, groundColour, intensity ] = sky.hemisphere
  scene.add(new THREE.HemisphereLight(skyColour, groundColour, intensity))

  const sun = new THREE.DirectionalLight(sky.sun, sky.sun_intensity)
  sun.position.set(...sky.sun_direction)
  sun.castShadow = quality.shadows
  sun.shadow.mapSize.set(quality.shadowMap, quality.shadowMap)
  sun.shadow.camera.near = 1
  sun.shadow.camera.far = 260
  const extent = 90
  sun.shadow.camera.left = -extent
  sun.shadow.camera.right = extent
  sun.shadow.camera.top = extent
  sun.shadow.camera.bottom = -extent
  sun.shadow.bias = -0.0008
  // (keep the existing normalBias comment)
  sun.shadow.normalBias = 0.06
  scene.add(sun)
  scene.add(sun.target)

  return { scene, sun }
}

// The sky as a tiny equirectangular gradient: zenith at the top, horizon across the
// middle, ground below. Sixteen by sixty-four texels is plenty for a gradient, and it is
// the one texture the environment map is filtered from.
export function skyTexture(sky) {
  const width = 16
  const height = 64
  const data = new Uint8Array(width * height * 4)
  const zenith = new THREE.Color(sky.zenith)
  const horizon = new THREE.Color(sky.horizon)
  const ground = new THREE.Color(sky.ground)
  const colour = new THREE.Color()
  for (let y = 0; y < height; y += 1) {
    // Row 0 is the bottom of the image (DataTexture, flipY false): ground up to horizon
    // in the lower half, horizon up to zenith in the upper.
    const t = y / (height - 1)
    if (t < 0.5) colour.copy(ground).lerp(horizon, Math.pow(t * 2, 0.6))
    else colour.copy(horizon).lerp(zenith, Math.pow((t - 0.5) * 2, 0.8))
    // The texture is sRGB and Color's channels are linear, so write the sRGB bytes that
    // getHex encodes rather than the linear channels scaled by 255.
    const hex = colour.getHex()
    for (let x = 0; x < width; x += 1) {
      const i = (y * width + x) * 4
      data[i] = (hex >> 16) & 255
      data[i + 1] = (hex >> 8) & 255
      data[i + 2] = hex & 255
      data[i + 3] = 255
    }
  }
  const texture = new THREE.DataTexture(data, width, height)
  texture.mapping = THREE.EquirectangularReflectionMapping
  texture.colorSpace = THREE.SRGBColorSpace
  texture.magFilter = THREE.LinearFilter
  texture.minFilter = THREE.LinearFilter
  texture.needsUpdate = true
  return texture
}
```

In `disposeScene`, before `scene.clear()`:

```js
  if (scene.background?.isTexture) scene.background.dispose()
  if (scene.environment?.isTexture) scene.environment.dispose()
```

- [ ] **Step 4: Choose the time in the engine and the controller**

In `app/javascript/game/engine.js`: the constructor takes `time`; store

```js
    // Day unless the URL says night. Physics does not care; this is only what it looks like.
    this.timeName = spec.rules.sky?.[time] ? time : "day"
    this.sky = spec.rules.sky?.[this.timeName]
    this.sunOffset = this.sky?.sun_direction ?? [ 48, 72, 36 ]
```

and replace `const { scene, sun } = createScene(this.quality)` with `const { scene, sun } = createScene(this.quality, this.sky, this.renderer)`. At the sun-follows-the-car line (about line 899), replace the literal `48, 72, 36` offsets with `this.sunOffset[0]`, `this.sunOffset[1]`, `this.sunOffset[2]`.

In `app/javascript/controllers/arena_controller.js`, pass

```js
      // Day or night. Only how the world is lit; the URL keeps it beside vehicle and spawn.
      time: new URLSearchParams(window.location.search).get("time") || "day",
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/system/looks_test.rb`
Expected: PASS.

Run: `bin/rails test test/system/street_test.rb test/system/building_test.rb test/system/driving_test.rb`
Expected: PASS — at `low` the background is a colour, so the draw counts and the timings stand.

- [ ] **Step 6: Commit**

```bash
git add app/javascript/game/render/scene.js app/javascript/game/engine.js app/javascript/controllers/arena_controller.js test/application_system_test_case.rb test/system/looks_test.rb
git commit -m "Light the world by day, from a sky the spec describes, and give steel a horizon to reflect

The sky is a gradient texture at high quality, filtered once into an environment map,
and the horizon colour at low. Night stays one parameter away (?time=night) with the
values the game was lit for until now.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: Lawns on the ground, in the roads' mesh

**Files:**
- Modify: `app/javascript/game/render/roads_view.js`
- Modify: `app/javascript/game/engine.js`
- Test: `test/system/geleen_test.rb`

**Interfaces:**
- Consumes: `spec.arena.buildings[*].lawns` (rings in the building's rotated frame, Task 4/5), `spec.rules.gardens`, `Looks#lawn()` (Task 6).
- Produces: `buildRoadsView(scene, roads, ground, rules = {}, { lawns = [], gardens = {}, looks = null } = {})` where `lawns` are WORLD-space rings; the mesh carries a `grass` vertex attribute (1 on lawn vertices, 0 on road vertices) and `mesh.userData.lawnVertices`. Hook `__arenaLawnVertices()`.

- [ ] **Step 1: Write the failing test**

Append to `test/system/geleen_test.rb` inside the class:

```ruby
  # Front gardens are lawns draped beside the road ribbons, in the same mesh, so they cost
  # no draw call; and a row that has gardens ships the rings they are drawn from.
  test "the estate's front gardens are drawn on the ground" do
    boot(match: "geleen-lawns")
    assert_operator page.evaluate_script("window.__arenaLawnVertices()"), :>, 100, "no lawn was draped"
    with_gardens = page.evaluate_script("window.__arenaBuildingIds().map(i => window.__arenaBuildingSpec(i)).filter(s => s.lawns && s.lawns.length > 0).length")
    assert_operator with_gardens, :>, 5, "fewer than six rows ship lawns"
    draws_before = page.evaluate_script("window.__arenaDraws()")
    assert_operator draws_before, :>, 0
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/system/geleen_test.rb -n test_the_estate_s_front_gardens_are_drawn_on_the_ground`
Expected: FAIL — `__arenaLawnVertices is not a function`.

- [ ] **Step 3: Drape the lawns with the ribbons**

In `app/javascript/game/render/roads_view.js`, change the signature and the body so lawns are added to the same buffers, with a `grass` attribute and the lawn texture:

```js
import * as THREE from "three"
import { TILE } from "game/render/looks"

const STEP = 5
// Lawns are subdivided finer than roads: a garden is a few metres across and has to
// follow the ground it lies on rather than bridge it.
const LAWN_STEP = 2

// Every road in the world, and every lawn, as ONE mesh. ...(keep the existing comment, add:)
// A lawn is a ring draped the same way, coloured grass and flagged `grass` so the one
// material can lay the lawn texture over it and leave the asphalt alone.
export function buildRoadsView(scene, roads, ground, rules = {}, { lawns = [], gardens = {}, looks = null } = {}) {
  if ((!roads || roads.length === 0) && lawns.length === 0) return null

  const lift = rules.lift ?? 0.03
  const colours = rules.colours ?? {}
  const positions = []
  const colors = []
  const grass = []
  const indices = []
  const colour = new THREE.Color()
  const height = ground || (() => 0)

  for (const road of roads || []) {
    // (the existing road loop, unchanged, plus one line per pushed vertex:)
    //   grass.push(0)
  }

  const lawnLift = gardens.lift ?? 0.02
  const grassColour = new THREE.Color(gardens.grass ?? "#4f7a36")
  let lawnVertices = 0
  for (const ring of lawns) {
    if (!ring || ring.length !== 4) continue
    const [ a, b, c, d ] = ring
    const n = Math.max(1, Math.ceil(Math.hypot(b[0] - a[0], b[1] - a[1]) / LAWN_STEP))
    const m = Math.max(1, Math.ceil(Math.hypot(d[0] - a[0], d[1] - a[1]) / LAWN_STEP))
    const base = positions.length / 3
    for (let j = 0; j <= m; j += 1) {
      for (let i = 0; i <= n; i += 1) {
        const s = i / n
        const t = j / m
        // Bilinear over the ring: a -> b along the first edge, a -> d along the last.
        const x = (1 - t) * ((1 - s) * a[0] + s * b[0]) + t * ((1 - s) * d[0] + s * c[0])
        const z = (1 - t) * ((1 - s) * a[1] + s * b[1]) + t * ((1 - s) * d[1] + s * c[1])
        positions.push(x, height(x, z) + lawnLift, z)
        const shade = 1 + (hash(x, z) - 0.5) * 0.12
        colors.push(grassColour.r * shade, grassColour.g * shade, grassColour.b * shade)
        grass.push(1)
        lawnVertices += 1
        if (i > 0 && j > 0) {
          const v = base + j * (n + 1) + i
          indices.push(v - n - 2, v - 1, v - n - 1, v - 1, v, v - n - 1)
        }
      }
    }
  }

  const geometry = new THREE.BufferGeometry()
  geometry.setAttribute("position", new THREE.Float32BufferAttribute(positions, 3))
  geometry.setAttribute("color", new THREE.Float32BufferAttribute(colors, 3))
  geometry.setAttribute("grass", new THREE.Float32BufferAttribute(grass, 1))
  geometry.setIndex(indices)
  geometry.computeVertexNormals()
  const material = new THREE.MeshStandardMaterial({
    vertexColors: true, roughness: 0.95, metalness: 0.02,
    polygonOffset: true, polygonOffsetFactor: -1, polygonOffsetUnits: -1
  })
  const lawn = looks?.lawn()
  if (lawn) {
    // One material, two surfaces: the lawn texture is laid in world metres and mixed in
    // by the `grass` flag, so the asphalt stays flat and the lawn reads as grass.
    material.map = lawn
    material.onBeforeCompile = (shader) => {
      shader.vertexShader = `attribute float grass;\nvarying float vGrass;\n#define TILE_METRES ${TILE.toFixed(1)}\n` +
        shader.vertexShader.replace("#include <uv_vertex>", `
#if defined( USE_UV ) || defined( USE_ANISOTROPY )
  vUv = uv;
#endif
#ifdef USE_MAP
  vMapUv = ( modelMatrix * vec4( position, 1.0 ) ).xz / TILE_METRES;
#endif
vGrass = grass;
`)
      shader.fragmentShader = "varying float vGrass;\n" +
        shader.fragmentShader.replace("#include <map_fragment>", `
#ifdef USE_MAP
  vec4 lawnTexel = texture2D( map, vMapUv );
  diffuseColor *= mix( vec4( 1.0 ), lawnTexel, vGrass );
#endif
`)
    }
    material.customProgramCacheKey = () => "roads-lawn"
  }
  const mesh = new THREE.Mesh(geometry, material)
  mesh.name = "roads"
  mesh.receiveShadow = true
  mesh.userData.lawnVertices = lawnVertices
  scene.add(mesh)
  return mesh
}

// A seeded value in [0, 1) per point, so a lawn is not one flat green.
function hash(x, z) {
  let h = (Math.round(x * 10) * 374761393 + Math.round(z * 10) * 668265263) | 0
  h = Math.imul(h ^ (h >>> 13), 1274126177)
  return ((h ^ (h >>> 16)) >>> 0) / 4294967296
}
```

Where the plan says "the existing road loop, unchanged, plus one line", keep the loop exactly as it is and add `grass.push(0)` immediately after each `colors.push(...)`. Check the triangle winding of the lawn quads matches the roads' (both should face up: `computeVertexNormals` gives +y for counter-clockwise seen from above); if the lawn comes out facing down (invisible from above, visible from below), swap the two triangles' second and third indices.

In `app/javascript/game/engine.js`, replace the `buildRoadsView(...)` call with:

```js
    // Lawns arrive per building in its rotated frame, like its surfaces; carried out to
    // the world by its position here, so the roads view knows nothing about buildings.
    const lawns = (this.spec.arena.buildings || []).flatMap((building) =>
      (building.lawns || []).map((ring) => ring.map(([ x, z ]) => [ x + building.o[0], z + building.o[2] ]))
    )
    this.roadsView = buildRoadsView(this.scene, this.spec.arena.roads, this.ground, this.spec.rules.roads,
                                    { lawns, gardens: this.spec.rules.gardens, looks: this.looks })
```

(`this.looks` must be created before this line; move the `Looks` construction up to right after the renderer if it is not already.) Add the hook:

```js
    window.__arenaLawnVertices = () => this.roadsView?.userData.lawnVertices ?? 0
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/system/geleen_test.rb test/system/looks_test.rb`
Expected: PASS. `"both islands boot…"` still asserts `__arenaRoadVertices() > 1000` — it counts the whole position attribute, so lawns only raise it.

Run: `bin/rails test test/system/street_test.rb`
Expected: PASS — the hand-made worlds have no lawns, and the roads mesh was already one draw where it existed.

- [ ] **Step 5: Commit**

```bash
git add app/javascript/game/render/roads_view.js app/javascript/game/engine.js test/system/geleen_test.rb
git commit -m "Drape the front gardens as lawns in the roads' mesh

A lawn is a ring draped on the ground like a ribbon, coloured grass, flagged so the
one material lays the lawn texture over it and leaves the asphalt flat. Rings arrive
per building in its frame and are carried out to the world by its position.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: Say how it works, photograph it, and prove nothing regressed

**Files:**
- Modify: `CLAUDE.md`
- Modify: `test/system/shots_test.rb`
- Test: everything named below

- [ ] **Step 1: Document the look in `CLAUDE.md`**

Add a section after "### What is left on the ground" and before "### Terrain":

```markdown
### How buildings look (`render/looks.js`, `piece_meshes.js`, `Game::Palettes`)

Every piece is still a box in an instanced pool, one pool per material. What changed is
how the pool's ONE material is dressed and how each instance is coloured.

- **The look lives in Ruby.** `Game::Material#look` — pattern, unit sizes in metres,
  joint width and shade, per-unit variation, relief, a value-space base — ships in
  `materials[*].look`. The client paints three textures per patterned material at boot
  (albedo, normal, roughness, 2 m × 2 m, seamless) from those numbers and holds none of
  its own; `TILE` and `SIZE` in `looks.js` are the drawing's shape, not tuning.
- **Texture coordinates are metres along the surface.** Each instance carries `cellUV`,
  its cell's offset along its surface, and a vertex chunk (`onBeforeCompile` replacing
  `uv_vertex`) maps the cube's faces from that plus the instance matrix's scale, so a
  bond runs across a wall and a hole shows brick ends. Glass is the exception: it maps
  per cell, so its frame goes round each pane.
- **Colour is `palette[role] × jitter × damage shade`, in the instance colour.** Pool
  materials are white. `Game::Palettes` is a frozen table like `Materials`; a recipe
  names one (`palette`, default `brown_brick`, tuned to the colours the hand-made worlds
  always had); a material names a `role`. Palettes carry `brick`, `roof_tile` and `door`
  only — one instance colour cannot colour a joint differently from its face. `low`
  quality paints nothing and keeps flat materials; palettes still apply.
- **Openings are styles** (`Openings::STYLES`): `classic` is byte for byte what the
  `building` recipe always had; a dwelling's front is a one-cell `door` with a two-cell
  window beside it; a box with `door: "garage"` gets a two-row door across its first
  edge; a church's nave, tower and chapel have rhythms of their own. Styles change
  patches, never grids, so nothing renumbers.
- **A hedge is pieces, a lawn is a picture.** A `row` with `gardens` appends one
  `kind: :hedge` surface per garden (storey −1, one row of cells, the path void) after
  the boxes and before the rubble; it is skipped by the collapse rule by storey, by name
  and by weight, and left out of the rubble mix. Lawns are rings the client drapes into
  the roads' mesh. The importer finds garages (a one-storey annex whose street edge is a
  car wide) and gardens (the strip to the nearest road across the front).
- **Daylight is the default.** `rules.sky.{day,night}`; `?time=night` is the sky the game
  was lit for until now. At high quality the sky is a gradient texture filtered once
  into an environment map so steel reflects something; at low it is the horizon colour.
```

Add `__arenaLooks`, `__arenaCellUV`, `__arenaTint`, `__arenaLawnVertices` to the hooks table under "Testing", one row each, in the table's style. Add `?time=night` to the "Useful URLs" line in Commands.

- [ ] **Step 2: Photograph it from the driver's seat**

In `test/system/shots_test.rb`, in `"photograph geleen"`, after `shot "21-geleen-church"` add:

```ruby
    # Close, which is where brick reads as brick or does not: three metres off a front.
    park_in_front_of(row, back: 3)
    shot "22-geleen-wall-at-three-metres"

    # A garage, if the import found one on the estate.
    garage = page.evaluate_script("window.__arenaBuildingIds().find(i => window.__arenaBuildingSpec(i).lawns && window.__arenaBuildingSpec(i).lawns.length > 0 && window.__arenaBuildingSpec(i).name.startsWith('estate-'))")
    park_in_front_of(garage, back: 10) if garage
    shot "23-geleen-garden-and-hedge" if garage

    # The same kerb, at night, for the comparison the default was chosen against.
    visit_world("geleen", vehicle: "buggy", quality: "high", match: "shots-geleen-night", time: "night")
    wait_for(timeout: 120, message: "geleen never booted at night") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
    wait_for(timeout: 120, message: "the world never stepped") { page.evaluate_script("window.__arena.steps").positive? }
    sleep 2.0
    press("g")
    press("h")
    park_in_front_of(row, back: 8)
    shot "24-geleen-row-at-night"
```

Run: `SHOTS=1 bin/rails test test/system/shots_test.rb -n test_photograph_geleen`
Expected: files `20…24` in `tmp/shots/`. Look at `22-geleen-wall-at-three-metres.png`: individual bricks, level courses across cells, a one-cell door in the door colour, a two-cell window with a frame. Look at `20-geleen-row-from-the-kerb.png`: a hedge with a gap at the path, a lawn between the hedge and the road, neighbouring rows in different palettes. List in your report what each shot shows, honestly, including anything that looks wrong.

- [ ] **Step 3: Run the checks that guard this work**

```bash
bin/rails test
bin/rubocop
bin/rails test test/system/looks_test.rb test/system/geleen_test.rb test/system/bays_test.rb test/system/street_test.rb test/system/building_test.rb test/system/collapse_test.rb test/system/rubble_test.rb
```

Expected: all green. Do NOT run the whole system suite; the controller does that once at the end.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md test/system/shots_test.rb
git commit -m "Say how buildings look, and photograph a wall from three metres

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Self-review

- **Spec coverage.** §1 look attribute → Task 1. §2 textures at boot → Task 6 (`paint`, three maps, mipmaps, anisotropy). §3 metres coordinates, cross-sections, slabs → Task 6 (`METRES_UV`, `cellUV`, `slab.tint`). §4 palettes per instance → Tasks 2, 5, 6 (roles narrowed to brick/roof_tile/door, recorded above). §5 door material, house fronts, garages, sheds solid (already), church rhythm, window frames in the glass texture → Tasks 1, 3, 5, 6. §6 front gardens, hedges as pieces after boxes before rubble, back gardens (fixed strip), lawns merged into the roads mesh with a lawn texture → Tasks 4, 5, 8. §7 daylight default, `?time=night`, environment map → Task 7. §8 tiers → Tasks 6, 7 (`QUALITY.textures`). Testing section → `materials_test`, `palettes_test`, `row_test`, `collapse_test`, `rows_test`, `looks_test`, `geleen_test`, `shots_test`. Migration notes → `CLAUDE.md` in Task 9; fixtures re-imported once in Task 5.
- **Placeholders.** Every code step carries its code; the two verification-by-eye steps (normal-map sign in Task 6, lawn winding in Task 8) name the exact change to make on each outcome.
- **Type consistency.** `Openings#door_columns(cols)` (Task 3) is what `Gardens.path_columns` calls (Task 4). `Row#gardens` returns `Garden` structs with `.bay`/`.depth`, which `Gardens` reads. `Generator.lawns(recipe)` (Task 4) is what `WorldObject#to_building` calls, and `spec.arena.buildings[*].lawns` is what `engine.js` reads (Task 8). `PieceMeshes#add(name, matrix, colour, cellU, cellV)` (Task 6) is called with a `Color` from `Building#tintFor`, which `looks_test` reads back through `__arenaTint`. `Looks#lawn()` (Task 6) is called by `buildRoadsView` (Task 8). `QUALITY.textures` (Task 6) gates both `Looks` and `createScene` (Task 7).
