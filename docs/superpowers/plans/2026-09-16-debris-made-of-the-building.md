# Debris Made of the Building — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A collapsed building leaves a low pile of wreckage visibly made of its own brick, timber, tile and glass, that the truck ploughs through and a rocket takes a bite out of, and whose cleared heaps leave a few chunks lying for a moment before they fade into the ground.

**Architecture:** A heap keeps one piece index and one collider but is drawn as a base lump plus a seeded cluster of material fragments drawn from per-material instanced pools. Ruby ships the building's material mix on the rubble surface and a chunk profile per material; the client derives every fragment from those and the seed. Cleared heaps hand a few fragments to a `Remnants` pool of plain meshes that settle, linger and fade.

**Tech Stack:** Rails 8.1 (plain Ruby under `app/models/game/`), three.js 0.170 (vendored), Rapier wasm, Minitest, Capybara + headless Chrome for system tests.

**Spec:** `docs/superpowers/specs/2026-09-16-debris-made-of-the-building-design.md`

## Global Constraints

- Every tuning number lives in Ruby and ships in the spec; the JS holds no constants of its own beyond defaults that mirror Ruby's.
- Piece index space is never culled; `piece_count` must not change (the heap grid is untouched).
- Rubble surface stays `kind: :rubble`, `storey: -1`, appended last.
- No `Math.random` anywhere a heap is drawn; two clients must draw identical heaps.
- Rapier bodies are never created or freed inside a drain callback (nothing here creates bodies).
- Run one test file, not the suite, between tuning steps; the full system suite runs once at the end.
- Commit straight to `main`; end commit messages with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

---

### Task 1: Every material says how it breaks into chunks

**Files:**
- Modify: `app/models/game/material.rb`
- Modify: `app/models/game/materials.rb`
- Test: `test/models/game/materials_test.rb`

**Interfaces:**
- Produces: `Game::Material#chunk` → `{ size: [x, y, z], vary: Float, jitter: Float }` or `nil`; ships as `chunk` in `to_spec`. Local Y of a chunk is its THICKNESS (a plank lies flat, a tile lies flat); X is its length.

- [ ] **Step 1: Write the failing test**

Append to `test/models/game/materials_test.rb`:

```ruby
  # What a heap of wreckage is drawn from. Every material a building can be made of has
  # to say what a broken chunk of it looks like -- a plank, a plate, a block -- or the
  # client would have to invent one, and the client holds no numbers of its own.
  test "every material a building is made of says how it breaks into chunks" do
    Game::Materials.names.each do |name|
      material = Game::Materials.fetch(name)
      # Void is a hole and rubble is what the chunks sit IN; neither is ever a chunk.
      next if %i[void rubble].include?(name)

      chunk = material.chunk
      assert chunk, "#{name} has no chunk profile"
      assert_equal 3, chunk[:size].length, "#{name} chunk size is not x, y, z"
      chunk[:size].each { |extent| assert_operator extent, :>, 0, "#{name} chunk has a zero extent" }
      assert_operator chunk[:vary], :>=, 0
      assert_operator chunk[:vary], :<, 1.0, "#{name} chunks could shrink to nothing"
      assert_operator chunk[:jitter], :>=, 0
      assert_equal chunk, material.to_spec[:chunk], "#{name} does not ship its chunk"
    end

    assert_nil Game::Materials.fetch(:void).chunk
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/game/materials_test.rb`
Expected: FAIL with `NoMethodError: undefined method 'chunk'`

- [ ] **Step 3: Add `chunk` to Material**

In `app/models/game/material.rb`: add `:chunk` to `attr_reader`; add `chunk: nil` to `initialize`'s keyword list and set

```ruby
      # What a broken chunk of this looks like, once it is lying in a heap: a mean size on
      # each axis in metres, how much that varies, and how far off a box the shape is.
      # Local Y is the THICKNESS, so a plank and a tile lie flat and a brick is a block.
      # Nil for anything that is never a chunk -- a hole, and the heap itself.
      @chunk = chunk&.transform_keys(&:to_sym)&.freeze
```

and add `chunk: chunk,` to `to_spec`.

- [ ] **Step 4: Give every material its chunk, and re-colour rubble**

In `app/models/game/materials.rb` add to each entry (after `friction:` lines is fine):

```ruby
      brick:     chunk: { size: [ 0.55, 0.28, 0.30 ], vary: 0.45, jitter: 0.30 },
      concrete:  chunk: { size: [ 0.90, 0.35, 0.60 ], vary: 0.40, jitter: 0.25 },
      plaster:   chunk: { size: [ 0.70, 0.08, 0.50 ], vary: 0.40, jitter: 0.20 },
      timber:    chunk: { size: [ 1.40, 0.14, 0.18 ], vary: 0.35, jitter: 0.08 },
      glass:     chunk: { size: [ 0.35, 0.03, 0.30 ], vary: 0.50, jitter: 0.50 },
      roof_tile: chunk: { size: [ 0.45, 0.05, 0.40 ], vary: 0.30, jitter: 0.20 },
      steel:     chunk: { size: [ 1.20, 0.15, 0.15 ], vary: 0.30, jitter: 0.05 },
```

Change the rubble entry's colour from `"#4f4a3e"` to `"#7d7569"` and its comment: the heap's own material is now the DUST AND MORTAR the building's chunks sit in, so it is a neutral grey-brown that brick, timber and tile read against, not a colour of its own.

- [ ] **Step 5: Run the test and the material-dependent tests**

Run: `bin/rails test test/models/game/materials_test.rb test/models/game/spec_test.rb`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add app/models/game/material.rb app/models/game/materials.rb test/models/game/materials_test.rb
git commit -m "Say what a chunk of each material looks like

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: The wreckage knows what the house was made of

**Files:**
- Modify: `app/models/game/building/surface.rb`
- Modify: `app/models/game/building/rubble.rb`
- Test: `test/models/game/building/rubble_test.rb`

**Interfaces:**
- Produces: `Game::Building::Surface#mix` → `[[:brick, 0.376], [:timber, 0.26], …]` sorted by share descending, or `nil`; shipped as `mix: [["brick", 0.376], …]` only when present. `Game::Building::Rubble.mix_for(built)`; `Rubble::SHARE = 0.2`; `Rubble::SHAPES = 12`.

- [ ] **Step 1: Write the failing tests**

Append inside the class in `test/models/game/building/rubble_test.rb`:

```ruby
  # A heap is drawn from what the building was made of, in proportion. The shares are
  # worked out here from the surfaces the generator built, and shipped, so a bungalow with
  # a flat concrete roof leaves different wreckage from a gabled brick house without
  # anybody choosing a number.
  test "the wreckage is what the house was made of, by share" do
    mix = surface.mix

    assert mix, "the rubble surface carries no mix"
    assert_in_delta 1.0, mix.sum(&:last), 1e-6
    names = mix.map(&:first)
    assert_equal names, names.uniq
    refute_includes names, :void, "a hole is not a material"
    refute_includes names, :rubble, "rubble is what the chunks sit in, not a chunk"
    assert_equal :brick, names.first, "a brick house should be mostly brick"
    assert_includes names, :timber
    assert_equal mix, mix.sort_by { |name, share| [ -share, name ] }, "shares are shipped largest first"
  end

  test "the mix ships with the surface and nothing else carries one" do
    set = Game::Building::Generator.call(recipe)
    rubble = set.surfaces.last
    wall = set.surfaces.first

    assert_equal rubble.mix.map { |name, share| [ name.to_s, share.round(4) ] }, rubble.to_spec[:mix]
    assert_nil wall.mix
    refute wall.to_spec.key?(:mix), "a wall has no business shipping a mix"
  end

  # A pile the truck ploughs, not a hill it climbs. The share of the house that stays as
  # wreckage is a feel number and will move, but the CONSEQUENCE is what this pins: the
  # worked example's wreckage averages under a metre deep over its footprint.
  test "the pile is something a truck ploughs rather than a hill it climbs" do
    assert_operator surface.thickness, :<, 1.0,
                    "#{surface.thickness.round(2)}m of wreckage wall to wall is a hill"
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/models/game/building/rubble_test.rb`
Expected: FAIL with `NoMethodError: undefined method 'mix'`

- [ ] **Step 3: Carry `mix` on Surface**

In `app/models/game/building/surface.rb`: add `:mix` to `attr_reader`; add `mix: nil` to `initialize` and `@mix = mix`; add `mix: mix` to `with_offset`; and in `to_spec`, after `patches:`, make the hash conditional:

```ruby
        }.tap do |spec|
          # Only the rubble surface carries one: what the building was made of, by share of
          # volume, largest first. The client draws a heap's chunks from it in that order.
          spec[:mix] = mix.map { |name, share| [ name.to_s, share.round(4) ] } if mix
        end
```

(Wrap the existing literal in `{ ... }.tap do |spec| ... end`.)

- [ ] **Step 4: Compute the mix in Rubble and lower the pile**

In `app/models/game/building/rubble.rb`:

Change `SHARE = 0.6` to `SHARE = 0.2` and replace its comment's last paragraph with: at 0.2 the worked example averages 0.59m over its footprint and mounds to about 1.7m in the middle, with a rim of a hand's breadth. That is deliberately a pile the truck's blade meets and breaks rather than a slope its wheels climb: the truck rides up the rim and ploughs the middle, and a rocket takes a bite out of it. What made the pile impassable before was this number at 0.6.

Change `SHAPES = 16` to `SHAPES = 12` (the base lump is now the dust the chunks sit in, and twelve shapes of it are plenty; every material's chunks add a pool of their own on top).

In `build`, pass `mix: mix_for(built)` to `Surface.new` (after `seed:`).

Replace `material_volume` with:

```ruby
      # Every cubic metre the building is made of, by material. Voids are holes and weigh
      # nothing, and rubble is excluded because a building's wreckage cannot be made of
      # itself.
      def self.volumes_by_material(built)
        volumes = Hash.new(0.0)

        Array(built).each do |surface|
          next if surface.kind == :rubble

          surface.rows.times do |row|
            surface.cols.times do |col|
              material = surface.material_at(row, col)
              next if material.name == :void

              volumes[material.name] += surface.cell_area * surface.thickness
            end
          end
        end

        volumes
      end

      def self.material_volume(built)
        volumes_by_material(built).values.sum
      end

      # What the wreckage is drawn from: each material's share of the building's volume,
      # largest first. Sorted with the name as tie-break so the order is total, because
      # the client walks it in sequence to pick a chunk's material and two clients have to
      # walk the same list.
      def self.mix_for(built)
        volumes = volumes_by_material(built)
        total = volumes.values.sum
        return [] if total <= 0

        volumes.sort_by { |name, volume| [ -volume, name ] }
               .map { |name, volume| [ name, volume / total ] }
      end
```

- [ ] **Step 5: Run the rubble, generator, collapse and object-state tests**

Run: `bin/rails test test/models/game/building test/models/game/damage test/models/game/spec_test.rb test/models/world_summary_test.rb`
Expected: PASS (piece counts are unchanged; only the depth and the mix moved)

- [ ] **Step 6: Commit**

```bash
git add app/models/game/building/surface.rb app/models/game/building/rubble.rb test/models/game/building/rubble_test.rb
git commit -m "Ship what the house was made of with its wreckage, and lower the pile

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: The rules for drawing, growing and clearing a heap

**Files:**
- Modify: `app/models/game/spec.rb` (the `rubble:` block under `collapse:`)
- Test: `test/models/game/spec_test.rb`

**Interfaces:**
- Produces: `rules.collapse.rubble.fragments` (Integer), `.rise` (seconds), `.shards` (Integer), `.remnants: { keep:, settle:, linger:, fade: }`; `.falloff` becomes 1.2; `.tilt` is now the fragments' lean.

- [ ] **Step 1: Write the failing test**

Append to `test/models/game/spec_test.rb`, after the existing rubble test:

```ruby
  # How a heap is populated, how it arrives and what it leaves. All tuning, all in Ruby.
  test "the client is told how many chunks a heap holds and what clearing one leaves" do
    rubble = Game::Spec.default_rules.dig(:collapse, :rubble)

    assert_kind_of Integer, rubble.fetch(:fragments)
    assert_operator rubble.fetch(:fragments), :>, 0, "a heap of nothing is a lump"
    assert_operator rubble.fetch(:rise), :>=, 0
    assert_kind_of Integer, rubble.fetch(:shards)

    remnants = rubble.fetch(:remnants)
    assert_operator remnants.fetch(:keep), :>=, 1, "clearing a heap has to leave something"
    assert_operator remnants.fetch(:keep) + rubble.fetch(:shards), :<=, rubble.fetch(:fragments),
                    "a heap cannot leave more chunks than it had"
    assert_operator remnants.fetch(:settle), :>=, 0
    assert_operator remnants.fetch(:linger), :>, 0, "the pieces should lie there a moment"
    assert_operator remnants.fetch(:fade), :>, 0, "the pieces should fade rather than blink out"
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/game/spec_test.rb`
Expected: FAIL with `KeyError: key not found: :fragments`

- [ ] **Step 3: Add the rules**

In `app/models/game/spec.rb`, inside `rubble: { ... }`:

- Change `falloff: 1.8` to `falloff: 1.2` and replace its last paragraph: gentler now that the pile is low. Measured on the worked example at SHARE 0.2: 1.2 peaks at 1.7m, 1.5 at 1.9m, 1.8 at 2.0m. The blade tops out at about 1.3m, so 1.2 is the one where the middle of the pile is a heap the blade breaks rather than a wall it stops against.
- Change the `tilt` comment to: how far a CHUNK leans off level. The base lump is level now, because the collider is sized from it and forty tilted colliders are forty invisible ramps; the lean moved to the chunks, which is where a heap looks dropped rather than laid.
- Add, after `aspect:`:

```ruby
            # How many chunks of the building's own material sit in and on each heap. Fixed
            # per heap because the instanced pools are allocated once at boot and cannot
            # grow; rim heaps get the same number, smaller. Fourteen on forty-two heaps is
            # about six hundred instances for a house, spread over one pool per material.
            fragments: 14,
            # How long a revealed heap takes to rise out of the ground, in seconds. The
            # collider is there at once; only the drawing eases. Zero pops.
            rise: 0.45,
            # What clearing a heap does with its chunks: `keep` of them are left lying where
            # they were, settle onto the ground over `settle`, lie there for `linger`, then
            # fade out over `fade` while sinking away. `shards` more are thrown as debris in
            # their own materials, so the impact reads in the colours of what was hit. Both
            # are drawn from the heap's own chunks, so together they cannot exceed `fragments`.
            shards: 2,
            remnants: {
              keep: 3,
              settle: 0.35,
              linger: 2.0,
              fade: 1.5
            }
```

- [ ] **Step 4: Run the test**

Run: `bin/rails test test/models/game/spec_test.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/models/game/spec.rb test/models/game/spec_test.rb
git commit -m "Ship the rules for how a heap is populated, rises and is cleared

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: A heap in world space, and the chunks that sit in it

**Files:**
- Modify: `app/javascript/game/world/rubble.js`

**Interfaces:**
- Produces (all exported):
  - `heapFrame(surface, row, col, origin, rules, grow = 1, out = FRAME)` → `{ x, y, z, ground, yaw, a, b, height, top, relative, grow }`
  - `heapMatrix(surface, row, col, target, origin, rules, grow = 1)` → `target` (replaces `rubbleMatrix`; local z is world UP)
  - `heapFragments(surface, row, col, frame, mix, materials, rules, visit)` calls `visit(k, materialName, matrix)` for each chunk (matrix is a scratch, do not keep)
  - `fragmentMaterial(surface, row, col, k, mix)` → material name
  - `chunkGeometry(chunk)` → `THREE.BufferGeometry` (non-indexed, faceted, fills the unit box)
  - `fragmentPool(name)` → `` `${name}#rubble` ``, `isFragmentPool(pool)`, `FRAGMENT_SUFFIX`
  - `SHAPES = 12`; `shapeFor`, `pileOrder`, `lumpGeometry` unchanged.
- The JS side is covered by the system tests in Task 7; there is no JS unit runner in this repo.

- [ ] **Step 1: Replace `rubbleMatrix` with `heapFrame` + `heapMatrix`**

In `app/javascript/game/world/rubble.js`, delete `rubbleMatrix` and its comment block, and add:

```js
// Where one heap sits and how big it is, in WORLD space.
//
// The rubble grid always lies flat on the ground -- u east, v south, and a normal that
// points DOWN, which is what made every earlier attempt to lift or flatten a heap along
// the surface's own axes come out inverted. So a heap is placed in world terms from the
// start: a centre on the ground, a yaw about world up, two horizontal half-extents and a
// height. Nothing here reads the surface normal, and nothing here is Math.random: every
// number comes from the cell's own coordinates and the surface's seed, which is the whole
// reason two players see the same heap without a byte of it going over the wire.
//
// `grow` is how far risen the heap is, 0..1. A heap arrives by growing out of the ground
// rather than popping into it, and everything about it -- the lump's height, the chunks'
// size and where they sit -- is derived from the same frame, so the two cannot come apart.
export function heapFrame(surface, row, col, origin, rules = {}, grow = 1, out = FRAME) {
  const jitter = rules.jitter ?? 0.55
  const scale = rules.scale ?? 0.85
  const falloff = rules.falloff ?? 2.5
  const edge = rules.edge ?? 0.06
  const spread = rules.spread ?? 0.55
  const sink = rules.sink ?? [ 0.05, 0.45 ]

  cellMatrix(surface, row, col, MATRIX, origin)
  MATRIX.decompose(POSITION, ROTATION, SCALE)

  // Along the surface's own axes, so a nudge stays in the plane the heaps lie on.
  U.set(1, 0, 0).applyQuaternion(ROTATION)
  V.set(0, 1, 0).applyQuaternion(ROTATION)
  POSITION
    .addScaledVector(U, noise(surface, row, col, 11) * jitter * SCALE.x)
    .addScaledVector(V, noise(surface, row, col, 17) * jitter * SCALE.y)

  // Rubble piles toward the middle of what fell. A dome, and a VOLUME CONSERVING one: the
  // profile is divided by its own mean over the heaps, so the material Ruby computed is
  // neither created nor destroyed -- it is simply put where a pile puts it.
  const vary = 1 + noise(surface, row, col, 31) * spread
  const heap = vary * dome(surface, row, col, falloff, edge) / domeMean(surface, falloff, edge)
  // Plan proportion, per heap and area preserving.
  const aspect = 1 + noise(surface, row, col, 61) * (rules.aspect ?? 0.15)
  // How far the lump settles into the ground it landed on. Bounded well short of burying
  // it: a third has to stand proud or it stops being something you have to get around.
  const buried = sink[0] + ((noise(surface, row, col, 59) + 1) / 2) * (sink[1] - sink[0])
  const height = Math.max(SCALE.z * heap * grow, MIN_HEIGHT)

  // Cells are centred on their surface plane, and Ruby lifted the plane by half the depth
  // so a heap would sit ON the ground: the ground is therefore half a thickness below.
  out.ground = POSITION.y - Math.abs(surface.t) / 2
  out.x = POSITION.x
  out.z = POSITION.z
  out.y = out.ground + height / 2 - height * buried
  out.yaw = noise(surface, row, col, 23) * Math.PI
  out.a = SCALE.x * scale * vary * aspect / 2
  out.b = SCALE.y * scale * vary / aspect / 2
  out.height = height
  out.top = out.ground + height * (1 - buried)
  // How this heap compares with the average heap on the site: one at the mean, small at
  // the rim. The chunks shrink with it.
  out.relative = heap
  out.grow = grow
  return out
}

// The lump's transform: the frame as a box, spun about world up and NOT leaned. The
// collider is sized from this, and a car driving over forty leaned boxes is a car driving
// over forty invisible ramps; the lean lives on the chunks, where it reads as dropped
// rather than laid. Local z is world up -- lumpGeometry is squashed along z -- so the
// rotation carries local z onto world y before the yaw is applied.
export function heapMatrix(surface, row, col, target, origin, rules = {}, grow = 1) {
  const frame = heapFrame(surface, row, col, origin, rules, grow)

  ROTATION.setFromAxisAngle(WORLD_UP, frame.yaw).multiply(Z_UP)
  return target.compose(
    POSITION.set(frame.x, frame.y, frame.z),
    ROTATION,
    SCALE.set(frame.a * 2, frame.b * 2, frame.height)
  )
}

const MIN_HEIGHT = 0.01
const WORLD_UP = new THREE.Vector3(0, 1, 0)
// Rotates local +z onto world +y.
const Z_UP = new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(1, 0, 0), -Math.PI / 2)
const FRAME = {}
const MATRIX = new THREE.Matrix4()
```

- [ ] **Step 2: Add the chunks**

Append to `app/javascript/game/world/rubble.js`:

```js
// The chunks of the building's own material that sit in and on a heap.
//
// A heap has ONE piece index and ONE collider; these are only how it is drawn. Each chunk
// is an instance in a per-material pool -- `brick#rubble`, `timber#rubble` -- placed by a
// hash of the cell and its own ordinal, so every client puts the same plank in the same
// place. The material is drawn from the building's own mix, which Ruby computed from what
// the building was made of, so a brick house leaves brick and a concrete one leaves slabs.
//
// `visit` receives the chunk's ordinal, its material name and a matrix it must not keep.
export function heapFragments(surface, row, col, frame, mix, materials, rules = {}, visit) {
  const count = rules.fragments ?? 0
  const tilt = rules.tilt ?? 0.28
  if (!mix || mix.length === 0 || count <= 0) return

  // Rim heaps carry smaller chunks rather than fewer: the count is fixed because the pools
  // are sized up front, and scattered small chunks are what the edge of a pile looks like.
  // While the heap is still rising its chunks are rising with it.
  const size = (0.55 + 0.45 * Math.min(1, frame.relative)) * (0.5 + 0.5 * frame.grow)
  const cosYaw = Math.cos(frame.yaw)
  const sinYaw = Math.sin(frame.yaw)

  for (let k = 0; k < count; k += 1) {
    const name = fragmentMaterial(surface, row, col, k, mix)
    const chunk = materials[name]?.chunk || DEFAULT_CHUNK

    // Spread through the heap's ellipse, denser toward the middle -- the square root is
    // what makes a uniform draw uniform over AREA rather than bunched at the centre.
    const radius = Math.sqrt((fnoise(surface, row, col, k, 0) + 1) / 2)
    const angle = fnoise(surface, row, col, k, 1) * Math.PI
    const lx = Math.cos(angle) * radius * frame.a * 0.92
    const lz = Math.sin(angle) * radius * frame.b * 0.92

    const sx = chunk.size[0] * (1 + chunk.vary * fnoise(surface, row, col, k, 2)) * size
    const sy = chunk.size[1] * (1 + chunk.vary * fnoise(surface, row, col, k, 3)) * size
    const sz = chunk.size[2] * (1 + chunk.vary * fnoise(surface, row, col, k, 4)) * size

    // Sitting IN the top of the lump, some further in than others, and never below the
    // ground: the lump's crest falls away from its middle roughly as a dome does.
    const crest = frame.ground + (frame.top - frame.ground) * Math.sqrt(Math.max(0, 1 - radius * radius))
    const embed = 0.15 + 0.4 * ((fnoise(surface, row, col, k, 5) + 1) / 2)
    const y = Math.max(crest - sy * embed, frame.ground + sy * 0.35)

    // Its own yaw, then leaned off level about a horizontal axis. Local y stays roughly
    // up, which is what keeps a plank lying flat and a tile lying flat.
    ROTATION.setFromAxisAngle(WORLD_UP, fnoise(surface, row, col, k, 6) * Math.PI)
    const lean = fnoise(surface, row, col, k, 7) * Math.PI
    LEAN_AXIS.set(Math.cos(lean), 0, Math.sin(lean))
    SPIN.setFromAxisAngle(LEAN_AXIS, fnoise(surface, row, col, k, 9) * tilt)
    ROTATION.premultiply(SPIN)

    POSITION.set(
      frame.x + lx * cosYaw + lz * sinYaw,
      y,
      frame.z - lx * sinYaw + lz * cosYaw
    )
    visit(k, name, FRAGMENT.compose(POSITION, ROTATION, SCALE.set(sx, sy, sz)))
  }
}

// Which material chunk `k` of a heap is made of. A seeded draw against the cumulative
// mix, largest share first. Exported on its own because the pools are counted before any
// heap is built, and the count has to run exactly this draw.
export function fragmentMaterial(surface, row, col, k, mix) {
  const draw = (fnoise(surface, row, col, k, 8) + 1) / 2
  let reached = 0

  for (const [ name, share ] of mix) {
    reached += share
    if (draw < reached) return name
  }
  return mix[mix.length - 1][0]
}

export const FRAGMENT_SUFFIX = "#rubble"

// The pool a material's chunks are drawn from. The suffix chooses a SHAPE and never a
// material, exactly as `rubble#3` does: colour, opacity and everything else stay the
// material's.
export function fragmentPool(name) {
  return `${name}${FRAGMENT_SUFFIX}`
}

export function isFragmentPool(pool) {
  return pool.endsWith(FRAGMENT_SUFFIX)
}

// A chunk of something, not a box.
//
// A unit cube whose eight corners have each been shoved by a hash of their own position,
// then normalised to fill the unit box again so the instance scale is the chunk's real
// size. Non-indexed, so the lighting is faceted -- a chunk of masonry has faces. How far
// off a box it is comes from the material: a plank is nearly one, a shard of glass is not.
export function chunkGeometry(chunk = DEFAULT_CHUNK) {
  const jitter = (chunk.jitter ?? 0.3) * 0.5
  const corners = []
  for (let i = 0; i < 8; i += 1) {
    const x = i & 1 ? 0.5 : -0.5
    const y = i & 2 ? 0.5 : -0.5
    const z = i & 4 ? 0.5 : -0.5
    corners.push([
      x + hash(x, y, z, 1) * jitter,
      y + hash(x, y, z, 2) * jitter,
      z + hash(x, y, z, 3) * jitter
    ])
  }

  // Each face as a quad wound counter-clockwise seen from outside, split on a diagonal.
  // The corners are no longer coplanar, which is exactly the point.
  const quads = [
    [ 1, 3, 7, 5 ], [ 0, 4, 6, 2 ],
    [ 2, 6, 7, 3 ], [ 0, 1, 5, 4 ],
    [ 4, 5, 7, 6 ], [ 0, 2, 3, 1 ]
  ]
  const positions = []
  for (const [ a, b, c, d ] of quads) {
    positions.push(...corners[a], ...corners[b], ...corners[c])
    positions.push(...corners[a], ...corners[c], ...corners[d])
  }

  const geometry = new THREE.BufferGeometry()
  geometry.setAttribute("position", new THREE.Float32BufferAttribute(positions, 3))

  const position = geometry.attributes.position
  const box = new THREE.Box3().setFromBufferAttribute(position)
  const size = box.getSize(new THREE.Vector3())
  const centre = box.getCenter(new THREE.Vector3())
  for (let i = 0; i < position.count; i += 1) {
    position.setXYZ(
      i,
      (position.getX(i) - centre.x) / size.x,
      (position.getY(i) - centre.y) / size.y,
      (position.getZ(i) - centre.z) / size.z
    )
  }
  position.needsUpdate = true
  geometry.computeVertexNormals()
  return geometry
}

// What a chunk looks like when the material table has not said: a brick-sized block.
const DEFAULT_CHUNK = { size: [ 0.5, 0.3, 0.3 ], vary: 0.4, jitter: 0.3 }

// -1..1, deterministic in the surface's seed and offset, the cell, the chunk's ordinal and
// which of its numbers is wanted. A stronger mix than `noise` above, because a chunk's
// eight numbers are drawn from consecutive salts and the weak hash lines them up.
// Math.imul is exact 32-bit arithmetic in every engine, which is what makes this the same
// number on every client.
function fnoise(surface, row, col, k, j) {
  let h = Math.imul(((surface.seed ?? 0) + 0x9e3779b9) | 0, 0x85ebca6b)
  h = Math.imul(h ^ (surface.off + 1), 0xc2b2ae35)
  h = Math.imul(h ^ (row * 8191 + col + 1), 0x27d4eb2f)
  h = Math.imul(h ^ (k * 131 + j + 1), 0x165667b1)
  h ^= h >>> 15
  h = Math.imul(h, 0x2c1b3c6d)
  h ^= h >>> 12
  h = Math.imul(h, 0x297a2d39)
  h ^= h >>> 15
  return ((h >>> 0) / 4294967296) * 2 - 1
}

const FRAGMENT = new THREE.Matrix4()
```

Also change `export const SHAPES = 16` to `export const SHAPES = 12`, and make sure `SPIN`, `U`, `V`, `LEAN_AXIS`, `POSITION`, `ROTATION`, `SCALE` remain declared at the bottom (they are; remove `N`, which nothing uses now).

- [ ] **Step 3: Check the module still parses**

Run: `node --check app/javascript/game/world/rubble.js` (a syntax check only; the imports are importmap names and will not resolve, which is fine — `--check` does not run them).
Expected: no output

- [ ] **Step 4: Commit**

```bash
git add app/javascript/game/world/rubble.js
git commit -m "Place a heap in world space and derive the chunks that sit in it

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: What a cleared heap leaves lying there

**Files:**
- Create: `app/javascript/game/render/remnants.js`
- Modify: `app/javascript/game/render/piece_meshes.js` (add `shapeOf`)

**Interfaces:**
- Produces: `new Remnants({ scene, materials, rules, cap = 96 })`; `remnants.add(geometry, name, matrix)`; `remnants.update(dt)`; `remnants.count`; `remnants.dispose()`. `PieceMeshes#shapeOf(pool)` → the pool's geometry (unit cube if none).

- [ ] **Step 1: Write the Remnants class**

Create `app/javascript/game/render/remnants.js`:

```js
import * as THREE from "three"

// The couple of pieces of rubbish a cleared heap leaves lying where it was.
//
// A heap is an instanced piece and vanishes in the frame it breaks, which is right for a
// wall panel and wrong for a pile of garbage: a heap you drove through should leave a few
// chunks of itself behind that settle onto the ground, lie there a moment, and then fade
// away into it. These are those chunks.
//
// Plain meshes with a material EACH, not instances, because fading is a per-piece opacity
// and an InstancedMesh has one material. That is only affordable because there are never
// many -- three per heap, gone in four seconds -- and it is why the pool has a hard cap
// that retires the oldest rather than refusing the new.
//
// Purely local. Nothing about a remnant crosses the wire: the heap it came from is what
// is shared, and by the time one of these exists that heap is already gone everywhere.
export class Remnants {
  constructor({ scene, materials, rules = {}, cap = 96 }) {
    this.scene = scene
    this.materials = materials
    this.settleTime = rules.settle ?? 0.35
    this.lingerTime = rules.linger ?? 2.0
    this.fadeTime = rules.fade ?? 1.5
    this.cap = cap
    this.live = []
    this.pool = []
    this.templates = new Map()
  }

  templateFor(name) {
    if (this.templates.has(name)) return this.templates.get(name)

    const spec = this.materials[name] || {}
    const material = new THREE.MeshStandardMaterial({
      color: spec.colour || "#888888",
      roughness: spec.roughness ?? 0.85,
      metalness: spec.metalness ?? 0.05,
      opacity: spec.opacity ?? 1
    })
    this.templates.set(name, material)
    return material
  }

  // `matrix` is the chunk's transform as it lay in the heap. The geometry is the pool's
  // own, shared, so a remnant is the very chunk that was drawn there a frame ago.
  add(geometry, name, matrix) {
    if (this.live.length >= this.cap) this.retire(this.live[0], 0)

    const entry = this.take()
    const mesh = entry.mesh
    matrix.decompose(mesh.position, mesh.quaternion, mesh.scale)
    mesh.geometry = geometry
    mesh.material.copy(this.templateFor(name))
    mesh.material.transparent = true
    mesh.material.opacity = this.templateFor(name).opacity
    mesh.visible = true

    entry.age = 0
    entry.from = mesh.position.y
    entry.opacity = mesh.material.opacity
    // Where it comes to rest once the lump under it has gone: on the ground, a little into
    // it. Local y is the chunk's thickness and stays roughly up, so that is its height.
    // The ground is flat at y = 0 for every world so far, as it is for the shards.
    entry.rest = Math.max(mesh.scale.y, 0.05) * 0.35
    entry.depth = mesh.scale.length() * 0.6
    this.live.push(entry)
    return entry
  }

  take() {
    const entry = this.pool.pop()
    if (entry) return entry

    const mesh = new THREE.Mesh(PLACEHOLDER, new THREE.MeshStandardMaterial({ transparent: true }))
    mesh.castShadow = true
    mesh.receiveShadow = false
    this.scene.add(mesh)
    return { mesh, age: 0, from: 0, rest: 0, depth: 0, opacity: 1 }
  }

  // Settle, linger, then fade while sinking. The sink is deliberately not a scale fade:
  // the chunk's scale is what gives it its shape.
  update(dt) {
    for (let i = this.live.length - 1; i >= 0; i -= 1) {
      const entry = this.live[i]
      const mesh = entry.mesh
      entry.age += dt

      if (entry.age < this.settleTime) {
        const t = ease(entry.age / this.settleTime)
        mesh.position.y = entry.from + (entry.rest - entry.from) * t
        continue
      }

      const fading = entry.age - this.settleTime - this.lingerTime
      if (fading < 0) {
        mesh.position.y = entry.rest
        continue
      }
      if (fading >= this.fadeTime) {
        this.retire(entry, i)
        continue
      }

      const f = fading / this.fadeTime
      mesh.material.opacity = entry.opacity * (1 - f)
      mesh.position.y = entry.rest - entry.depth * f
    }
  }

  retire(entry, index = this.live.indexOf(entry)) {
    if (index < 0) return

    entry.mesh.visible = false
    this.live.splice(index, 1)
    this.pool.push(entry)
  }

  get count() {
    return this.live.length
  }

  dispose() {
    for (const entry of [ ...this.live, ...this.pool ]) {
      entry.mesh.removeFromParent()
      entry.mesh.material.dispose()
    }
    for (const material of this.templates.values()) material.dispose()
    this.live = []
    this.pool = []
    this.templates.clear()
  }
}

function ease(t) {
  return 1 - (1 - t) * (1 - t)
}

const PLACEHOLDER = new THREE.BoxGeometry(1, 1, 1)
```

- [ ] **Step 2: Expose a pool's geometry**

In `app/javascript/game/render/piece_meshes.js`, after `useShape`:

```js
  // The geometry a pool draws with, so something that wants to draw one more of the same
  // chunk outside the pool -- a remnant left lying after its heap is cleared -- draws the
  // very shape the pool did.
  shapeOf(name) {
    return this.shapes.get(name) || this.geometry
  }
```

- [ ] **Step 3: Syntax check and commit**

Run: `node --check app/javascript/game/render/remnants.js && node --check app/javascript/game/render/piece_meshes.js`
Expected: no output

```bash
git add app/javascript/game/render/remnants.js app/javascript/game/render/piece_meshes.js
git commit -m "Let a cleared heap leave a few chunks lying that settle, linger and fade

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: A heap is drawn as a lump and its chunks, rises when revealed, and clears into remnants

**Files:**
- Modify: `app/javascript/game/world/building.js`
- Modify: `app/javascript/game/world/buildings.js`
- Modify: `app/javascript/game/engine.js` (two hooks)

**Interfaces:**
- Consumes: everything from Tasks 4 and 5.
- Produces: `Building.countMaterials(spec, into, rubbleRules)`; `building.update(dt)`; `building.heapFragmentMaterials(index)` → `string[]`; `buildings.remnantCount`; `window.__arenaHeapFragments(piece, id)`, `window.__arenaRemnants()`.

- [ ] **Step 1: Building — imports and construction**

In `app/javascript/game/world/building.js` replace the rubble import with:

```js
import { heapMatrix, heapFrame, heapFragments, fragmentMaterial, fragmentPool, shapeFor, pileOrder, SHAPES } from "game/world/rubble"
import { baseMaterial } from "game/render/piece_meshes"
```

Add `remnants = null` to the constructor's destructured options and set `this.remnants = remnants`. After `this.blockCells = []` add:

```js
    // For a heap: which pool and slot each of its chunks was drawn into. Undefined for
    // everything that is not a heap, which is what `isHeap` tests.
    this.fragments = new Array(count)
    // Heaps still growing out of the ground, as { index, t }.
    this.rising = []
    this.rise = this.rubbleRules.rise ?? 0
```

- [ ] **Step 2: Count chunks per pool**

Replace `countMaterials` with:

```js
  // Tallied first, because an InstancedMesh cannot grow once allocated. A heap counts its
  // base lump AND every chunk sitting in it, each against the pool it will be drawn from,
  // by running exactly the material draw the builder runs.
  static countMaterials(spec, into = new Map(), rubbleRules = {}) {
    const shapes = rubbleRules.shapes ?? SHAPES
    const fragments = rubbleRules.fragments ?? 0

    for (const surface of spec.surfaces) {
      for (let row = 0; row < surface.rows; row += 1) {
        for (let col = 0; col < surface.cols; col += 1) {
          const name = materialAt(surface, row, col)
          if (name === "void") continue

          const pool = Building.poolName(surface, row, col, name, shapes)
          into.set(pool, (into.get(pool) || 0) + 1)
          if (surface.kind !== "rubble" || !surface.mix) continue

          for (let k = 0; k < fragments; k += 1) {
            const chunk = fragmentPool(fragmentMaterial(surface, row, col, k, surface.mix))
            into.set(chunk, (into.get(chunk) || 0) + 1)
          }
        }
      }
    }
    return into
  }
```

- [ ] **Step 3: Build a heap as lump plus chunks, hidden**

In `build`, replace the `if (rubble) rubbleMatrix(...)` line with:

```js
      if (rubble) heapMatrix(surface, row, col, matrix, this.origin, this.rubbleRules)
```

and replace the `if (rubble) { ... return }` block after `createCollider` with:

```js
      // Built now and revealed later. The collider array and the instance pools are both
      // allocated at boot and cannot grow, so the only way a heap can appear when a house
      // comes down is for it to have been here, switched off, all along -- the lump and
      // every chunk in it.
      if (rubble) {
        this.fragments[index] = this.buildFragments(surface, row, col)
        this.state[index] = DORMANT
        this.hideHeap(index)
        this.colliders[index]?.setEnabled(false)
        return
      }
```

Add these methods after `createCollider`:

```js
  // The chunks of the building's own material that sit in this heap, each added to its
  // material's pool. Their transforms are not kept: they are recomputed from the seed
  // whenever the heap is shown, which is what lets a heap rise and lets a cleared one hand
  // its chunks on without holding six hundred matrices per house.
  buildFragments(surface, row, col) {
    const frame = heapFrame(surface, row, col, this.origin, this.rubbleRules, 1, FRAME)
    const pools = []
    const slots = []

    heapFragments(surface, row, col, frame, surface.mix, this.materials, this.rubbleRules, (k, name, matrix) => {
      const pool = fragmentPool(name)
      pools.push(pool)
      slots.push(this.meshes.add(pool, matrix))
    })
    return { pools, slots }
  }

  isHeap(index) {
    return this.fragments[index] !== undefined
  }

  cellOf(index) {
    const surface = this.spec.surfaces[this.surfaceOf[index]]
    const local = index - surface.off
    return { surface, row: Math.floor(local / surface.cols), col: local % surface.cols }
  }

  // Draw the heap at `grow` of its full height: the lump and every chunk, all derived from
  // one frame so they rise together.
  showHeap(index, grow = 1) {
    const { surface, row, col } = this.cellOf(index)
    heapMatrix(surface, row, col, HEAP_MATRIX, this.origin, this.rubbleRules, grow)
    this.meshes.setVisible(this.pool[index], this.slot[index], true, HEAP_MATRIX)

    const chunks = this.fragments[index]
    if (!chunks) return
    const frame = heapFrame(surface, row, col, this.origin, this.rubbleRules, grow, FRAME)
    heapFragments(surface, row, col, frame, surface.mix, this.materials, this.rubbleRules, (k, name, matrix) => {
      this.meshes.setVisible(chunks.pools[k], chunks.slots[k], true, matrix)
    })
  }

  hideHeap(index) {
    this.meshes.setVisible(this.pool[index], this.slot[index], false)
    const chunks = this.fragments[index]
    if (!chunks) return
    for (let k = 0; k < chunks.slots.length; k += 1) {
      this.meshes.setVisible(chunks.pools[k], chunks.slots[k], false)
    }
  }

  // Damage darkening, over the lump and its chunks alike.
  tintPiece(index, ratio) {
    this.meshes.tint(this.pool[index], this.slot[index], ratio)
    const chunks = this.fragments[index]
    if (!chunks) return
    for (let k = 0; k < chunks.slots.length; k += 1) {
      this.meshes.tint(chunks.pools[k], chunks.slots[k], ratio)
    }
  }

  // What a heap leaves when it is cleared: a few of its own chunks left lying to settle
  // and fade, and a couple thrown as shards in their own materials. Both are its chunks,
  // in the very places they were drawn.
  clearHeap(index, away) {
    const keep = this.rubbleRules.remnants?.keep ?? 0
    const shards = this.rubbleRules.shards ?? 0
    if (keep + shards === 0) return

    const { surface, row, col } = this.cellOf(index)
    const frame = heapFrame(surface, row, col, this.origin, this.rubbleRules, 1, FRAME)
    heapFragments(surface, row, col, frame, surface.mix, this.materials, this.rubbleRules, (k, name, matrix) => {
      if (k < keep) this.remnants?.add(this.meshes.shapeOf(fragmentPool(name)), name, matrix)
      else if (k < keep + shards) this.debris?.spawn(matrix, name, { away, force: 0.6 })
    })
  }

  // Heaps grow out of the ground rather than popping into it. The collider was enabled the
  // moment the heap was revealed; only the drawing eases.
  update(dt) {
    for (let i = this.rising.length - 1; i >= 0; i -= 1) {
      const heap = this.rising[i]
      if (this.state[heap.index] !== INTACT) {
        this.rising.splice(i, 1)
        continue
      }

      heap.t += dt / this.rise
      const t = Math.min(heap.t, 1)
      this.showHeap(heap.index, 1 - (1 - t) * (1 - t))
      if (t >= 1) this.rising.splice(i, 1)
    }
  }

  // Which materials this heap's chunks are made of, one entry per chunk. For the tests:
  // it is how "the wreckage is made of what the house was made of" becomes an assertion.
  heapFragmentMaterials(index) {
    return this.fragments[index]?.pools.map(baseMaterial) ?? []
  }
```

Add at the bottom, beside the other scratch objects:

```js
const HEAP_MATRIX = new THREE.Matrix4()
const FRAME = {}
```

- [ ] **Step 4: Route damage, breaking, revealing and restoring through the heap methods**

In `damageCell`, replace the `this.meshes.tint(this.pool[index], ...)` line with `this.tintPiece(index, this.health[index] / this.maxHealth[index])`.

In `breakCell`, replace the two lines that spawn shards and hide the instance with:

```js
    const wasStanding = this.state[index] === INTACT
    this.state[index] = BROKEN
    if (this.isHeap(index)) {
      // A heap that was actually there leaves something behind; one cleared in some earlier
      // session and applied silently, or never revealed at all, leaves nothing.
      if (wasStanding && !silent) this.clearHeap(index, away)
      this.hideHeap(index)
    } else {
      // Shards before the piece goes: they are spawned from the transform the piece had,
      // which is still on hand either way, but doing it in this order keeps the two reads
      // of that matrix next to each other.
      if (!carried && !silent) this.debris?.spawn(this.matrices[index], this.material[index], { away })
      this.meshes.setVisible(this.pool[index], this.slot[index], false)
    }
```

(and delete the earlier `this.state[index] = BROKEN` line so it is set once, after `wasStanding` is read.)

In `reveal`, replace the `setVisible(... true, this.matrices[index])` and `tint` lines with:

```js
    if (this.rise > 0) {
      this.showHeap(index, 0)
      this.rising.push({ index, t: 0 })
    } else {
      this.showHeap(index, 1)
    }
    this.tintPiece(index, 1)
```

In `restoreCell`, replace the `setVisible` and `tint` lines with:

```js
    if (this.isHeap(index)) this.showHeap(index, 1)
    else this.meshes.setVisible(this.pool[index], this.slot[index], true, this.matrices[index])
    this.tintPiece(index, 1)
```

- [ ] **Step 5: Buildings — register chunk shapes, own the remnants, tick the buildings**

In `app/javascript/game/world/buildings.js`:

Replace the rubble import with
```js
import { lumpGeometry, chunkGeometry, isFragmentPool, SHAPES } from "game/world/rubble"
import { Remnants } from "game/render/remnants"
import { baseMaterial } from "game/render/piece_meshes"
```

After `this.falling = new FallingPieces(...)` and before `if (specs.length === 0) return`:

```js
    const rubbleRules = spec.rules.collapse?.rubble || {}
    // Built whether or not there are buildings, for the same reason the falling pool is.
    this.remnants = new Remnants({ scene, materials, rules: rubbleRules.remnants })
```

Replace the counting and shape registration block with:

```js
    // Counted across every building first, because an InstancedMesh is allocated once at
    // its final capacity and cannot grow afterwards. A heap counts its lump and every
    // chunk in it.
    const counts = new Map()
    for (const building of specs) Building.countMaterials(building, counts, rubbleRules)
    // Before allocate, and that ordering is the contract: a pool is handed its geometry
    // when its InstancedMesh is built and cannot be given a different one afterwards.
    const shapes = rubbleRules.shapes ?? SHAPES
    for (let variant = 0; variant < shapes; variant += 1) {
      this.meshes.useShape(`rubble#${variant}`, lumpGeometry(variant))
    }
    // One chunk shape per material that any building's wreckage is made of. The pool is
    // named for the material, so its colour, opacity and health are the material's; only
    // the shape is this file's.
    for (const pool of counts.keys()) {
      if (isFragmentPool(pool)) this.meshes.useShape(pool, chunkGeometry(materials[baseMaterial(pool)]?.chunk))
    }
    this.meshes.allocate(counts)
    // Before the loop starts, so the first explosion is not also the first tessellation.
    // By MATERIAL, not by pool: `rubble#3` and `brick#rubble` break as rubble and brick.
    this.patterns.warm(new Set([ ...counts.keys() ].map(baseMaterial)))
```

Pass `remnants: this.remnants,` and `rubbleRules,` (already passed as `rubbleRules: spec.rules.collapse?.rubble` — change to `rubbleRules`) into `new Building({...})`.

Replace `update(dt)` with:

```js
  update(dt) {
    this.debris.update(dt)
    this.falling.update(dt)
    this.remnants.update(dt)
    for (const building of this.list) building.update(dt)
  }
```

Add a getter beside `debrisCount`:

```js
  // Chunks left lying by cleared heaps, still visible. Zero once they have all faded.
  get remnantCount() {
    return this.remnants.count
  }
```

and `this.remnants.dispose()` in `dispose`, after `this.debris.dispose()`.

- [ ] **Step 6: Engine hooks**

In `app/javascript/game/engine.js`, after the `__arenaPieceMatrix` hook:

```js
    // Which materials a heap's chunks are made of. "The wreckage is made of what the house
    // was made of" is an assertion about this, and two players seeing the same chunks is
    // an assertion about it agreeing across sessions.
    window.__arenaHeapFragments = (piece, buildingId) =>
      this.buildings?.find(buildingId)?.heapFragmentMaterials(piece) ?? []
    // Chunks left lying by cleared heaps. Positive the moment a heap clears, zero once
    // they have faded -- which is the whole of what clearing a heap is meant to look like.
    window.__arenaRemnants = () => this.buildings?.remnantCount ?? 0
```

- [ ] **Step 7: Boot it in the browser and look**

With the preview server up, load `/?world=targets&vehicle=monster_truck&quality=high&match=look-<n>`, bring the house down via the hooks (two ground-floor walls, `__arenaDamagePiece(i, 5000, id)`), park the truck in front with `__arenaPlace`, and screenshot. Check: the console has no errors; heaps show brick/timber/tile chunks in a grey lump; the pile is knee-to-chest high; clearing a heap (`__arenaDamagePiece(pile, 5000, id)`) leaves chunks that fade.

- [ ] **Step 8: Run the existing rubble and collapse system tests**

Run: `bin/rails test test/system/rubble_test.rb test/system/collapse_test.rb`
Expected: PASS (the shape test measures `lumpGeometry` and heap matrices; both still hold)

- [ ] **Step 9: Commit**

```bash
git add app/javascript/game/world/building.js app/javascript/game/world/buildings.js app/javascript/game/engine.js
git commit -m "Draw a heap as a lump of the building's own chunks that rises, and clears into remnants

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Prove it in the browser

**Files:**
- Modify: `test/system/rubble_test.rb`

- [ ] **Step 1: Add the assertions**

Append inside `RubbleTest`:

```ruby
  # The picture, as an assertion. A heap is drawn from chunks of what the house was made of,
  # so over the whole site the chunks are brick and timber and tile, not one drab material.
  test "the wreckage is made of what the house was made of" do
    building = boot("rubble-materials")
    wreck_storey(building, 0)
    wait_for_the_dust_to_settle

    materials = page.evaluate_script(<<~JS, building)
      (function (id) {
        const s = window.__arenaBuildingSpec(id).surfaces.find(x => x.kind === "rubble")
        const seen = {}
        for (let i = s.off; i < s.off + s.cols * s.rows; i++) {
          if (!window.__arenaPieceState(i, id).standing) continue
          for (const name of window.__arenaHeapFragments(i, id)) seen[name] = (seen[name] || 0) + 1
        }
        return seen
      })(arguments[0])
    JS

    assert_operator materials.keys.length, :>=, 3, "the wreckage is one material: #{materials.inspect}"
    assert_includes materials.keys, "brick", "a brick house left no brick"
    assert_includes materials.keys, "timber"
    assert_equal "brick", materials.max_by { |_, count| count }.first,
                 "a house that is mostly brick should leave mostly brick: #{materials.inspect}"
  end

  # Requirement five, end to end: clearing a heap leaves a few chunks lying, and they are
  # gone again once they have settled, lingered and faded.
  test "clearing a heap leaves a few chunks that fade away" do
    building = boot("rubble-remnants")
    wreck_storey(building, 0)
    wait_for_the_dust_to_settle

    pile = a_standing_pile(building)
    assert_operator pile, :>=, 0, "no standing heap to clear"
    assert_equal 0, page.evaluate_script("window.__arenaRemnants()"), "remnants before anything was cleared"

    page.execute_script("window.__arenaDamagePiece(arguments[0], 5000, arguments[1])", pile, building)
    assert_operator page.evaluate_script("window.__arenaRemnants()"), :>, 0,
                    "clearing a heap left nothing lying"

    remnants = Game::Spec.default_rules.dig(:collapse, :rubble, :remnants)
    lifetime = remnants[:settle] + remnants[:linger] + remnants[:fade]
    wait_for(timeout: lifetime + 5, message: "the remnants never faded") do
      page.evaluate_script("window.__arenaRemnants()").zero?
    end
  end
```

And in the existing "two players see the same heaps in the same places" test, change the pushed entry so it also carries the chunks:

```js
              out.push([ i ].concat(m.map(v => Math.round(v * 1000) / 1000), window.__arenaHeapFragments(i, id)))
```

- [ ] **Step 2: Run the file**

Run: `bin/rails test test/system/rubble_test.rb`
Expected: PASS, all tests

- [ ] **Step 3: Commit**

```bash
git add test/system/rubble_test.rb
git commit -m "Prove the wreckage is made of the house and that clearing it leaves chunks that fade

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: The truck ploughs through the pile

**Files:**
- Modify: `test/system/breakthrough_test.rb`

- [ ] **Step 1: Calibrate in the browser**

On the preview: collapse the targets house, wait for the dust, `__arenaPlace = { x: 26, y: 2, z: -14, yaw: 0 }`, `__arenaInput = { throttle: 1 }`, and sample `__arena.planarSpeed`, the truck's z and `__arenaRubble().cleared` every 50ms for eight seconds. Note how long it takes to pass z = 24 and the lowest planar speed inside z 8..23. Adjust `SHARE`, `falloff` or heap health only if the truck stalls; otherwise leave the numbers.

- [ ] **Step 2: Write the test**

Append to `BreakthroughTest`:

```ruby
  # Requirement three, for the truck. A collapsed house's wreckage is something the truck
  # clears THROUGH rather than climbs or stops against: it rides the shallow rim, the blade
  # breaks the heaps tall enough to meet it, and it comes out the far side still moving,
  # having cleared some of them on the way.
  #
  # Asserted as arrival rather than as a speed profile, because arrival is what the driver
  # sees and a speed sampled from Ruby is a lottery. The margin is the whole house: the
  # pile spans z 8..23 and the truck has to be past 24.
  test "the truck ploughs through a fallen house's wreckage" do
    building = page.evaluate_script("window.__arenaBuildingIds()[0]")
    page.execute_script(<<~JS, building)
      const id = arguments[0]
      const spec = window.__arenaBuildingSpec(id)
      const walls = spec.surfaces.filter(s => s.kind === "wall" && s.storey === 0)
      for (const s of walls.slice(0, 2)) {
        for (let i = s.off; i < s.off + s.cols * s.rows; i++) window.__arenaDamagePiece(i, 5000, id)
      }
    JS
    wait_for(timeout: 25, message: "the house never came down") do
      page.evaluate_script("window.__arenaFalling()").zero? && page.evaluate_script("window.__arenaRubble().dormant").zero?
    end
    standing = page.evaluate_script("window.__arenaRubble().standing")
    assert_operator standing, :>, 0, "nothing to plough through"

    page.execute_script("window.__arenaPlace = { x: #{FRONT_X}, y: 2.0, z: -14, yaw: 0 }")
    sleep 1.0
    page.execute_script("window.__arenaInput = { throttle: 1 }")

    wait_for(timeout: 12, message: "the truck never came out the far side of the wreckage") do
      page.evaluate_script("window.__arena.position[2]") > 24
    end
    page.execute_script("window.__arenaInput = null")

    assert_operator page.evaluate_script("window.__arenaRubble().cleared"), :>, 0,
                    "the truck crossed the site without clearing a single heap"
  end
```

(If `__arena.position` is not the vehicle's position in the telemetry, use whichever telemetry field holds it — check `app/javascript/game/telemetry.js` — and adjust.)

- [ ] **Step 3: Run the file**

Run: `bin/rails test test/system/breakthrough_test.rb`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add test/system/breakthrough_test.rb
git commit -m "Prove the truck ploughs through a fallen house's wreckage

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: Write it down, run everything once

**Files:**
- Modify: `CLAUDE.md` (the "What is left on the ground" section and the hooks table)

- [ ] **Step 1: Update CLAUDE.md**

In the rubble section: state that a heap is drawn as a base lump plus `rules.collapse.rubble.fragments` chunks of the building's own materials, drawn from `${material}#rubble` pools; that Ruby ships `mix` on the rubble surface and `chunk` per material; that heaps are placed in WORLD space now (`heapFrame`), so the "which axis is up" bullet becomes: local z of the lump is world up by construction, and nothing reads the surface normal; that `SHARE` is 0.2 and why; that clearing a heap hands `remnants.keep` chunks to `Remnants` and throws `shards` more. Add `__arenaHeapFragments` and `__arenaRemnants` to the hooks table. Update `SHAPES` mentions (twelve). Keep it as terse as the surrounding prose allows.

- [ ] **Step 2: Lint and unit tests**

Run: `bin/rubocop && bin/rails test`
Expected: no offences, all green

- [ ] **Step 3: Stop the preview server, run the whole system suite once, capture it to a file**

Run: `bin/rails test:system > /private/tmp/.../scratchpad/final-system.log 2>&1; tail -20 that file`
Expected: all green. If a timing test fails, re-run that ONE file before concluding anything.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "Write down what a fallen house leaves behind, second pass

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```
