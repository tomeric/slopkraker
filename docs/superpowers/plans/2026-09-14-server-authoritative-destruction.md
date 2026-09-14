# Server-authoritative destruction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the server the authority on what a match has destroyed, so a collapse actually
reaches the browser, damage survives a reload, and two players see the same wreckage.

**Architecture:** Clients keep predicting their own breaks and never revert them. They report
the cells they hit over `ArenaChannel`; one authoritative process accumulates that into
per-match piece bitsets, runs `Game::Damage::Collapse`, and broadcasts `breaks` back to
everyone. State is held in memory under a per-match `Monitor` and flushed to `object_damages`
about once a second, so play never waits on SQLite.

**Tech Stack:** Rails 8.1, ActionCable (solid_cable), SQLite/WAL, three.js + Rapier in the browser.

**Spec:** `docs/superpowers/specs/2026-09-13-persistent-world-design.md` — §10 (server-authoritative
damage), §11 (collapse, already built), plus the "Edge cases" section.

## Global Constraints

- **Monotone in both directions.** A piece goes standing → broken and never back. `collapsed_from`
  goes NULL → lower and is never raised. Every server message is therefore idempotent, and a
  client that already broke a piece ignores any `state` that says it is standing.
- **Every tuning number lives in Ruby** and ships in the spec. No new constant may appear in
  JavaScript.
- **`Game::Damage::Collapse` is server-side only** and must not be ported. It is already built
  and tested; this plan only calls it.
- **`app/models/game/**` are POROs that never touch the database.** Anything needing a row goes
  in `app/models/*.rb` or is passed in.
- **Damage travels only over ActionCable; geometry only over HTTP.** Never mix them in one payload.
- **Rapier rule:** colliders are only enabled/disabled, never created or freed on a break.
- **Absorb arithmetic must match `game/damage.js` exactly:**
  `material.absorb(raw * material.multiplier_for(kind), rules[:damage][:minimum_fraction])`.
- **rails-omakase style.** `bin/rubocop` must be clean.
- Run `bin/rails test` (fast, no browser) after every task. Run system tests only in the task
  that adds one.

---

### Task 1: `Game::Damage::PieceSet` — the bitset

The `object_damages.destroyed` blob. A thousand-piece building is a 182-byte column rather
than a thousand rows, which is the whole reason this design scales.

**Files:**
- Create: `app/models/game/damage/piece_set.rb`
- Test: `test/models/game/damage/piece_set_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `PieceSet.new(size)` → empty set sized for `size` piece indices
  - `PieceSet.from_blob(blob, size)` → set restored from a binary column
  - `#add(index)` → `true` if it was not already present, `false` if it was
  - `#include?(index)` → Boolean
  - `#count` → Integer
  - `#to_blob` → binary String, `(size / 8.0).ceil` bytes
  - `#to_a` → sorted Array of set indices
  - Out-of-range `index` (negative, or `>= size`) raises `ArgumentError` from both `#add` and
    `#include?`.

Byte `index / 8`, bit `index % 8`, least-significant bit first. That ordering is arbitrary but
must never change — it is what a stored blob means.

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"

class Game::Damage::PieceSetTest < ActiveSupport::TestCase
  test "a fresh set holds nothing" do
    set = Game::Damage::PieceSet.new(20)

    assert_equal 0, set.count
    refute set.include?(0)
    assert_empty set.to_a
  end

  # Bit 0, bit 7 and bit 8 are the boundaries worth naming: the first bit of the first
  # byte, the last bit of the first byte, and the first bit of the second. An off-by-one
  # in the byte/bit split shows up at exactly one of these and nowhere else.
  test "the byte and bit boundaries land where they should" do
    set = Game::Damage::PieceSet.new(20)
    [ 0, 7, 8 ].each { |index| set.add(index) }

    assert_equal [ 0, 7, 8 ], set.to_a
    assert_equal "\x81\x01\x00".b, set.to_blob
  end

  test "adding twice reports the second as no change" do
    set = Game::Damage::PieceSet.new(20)

    assert set.add(3), "the first add is a change"
    refute set.add(3), "the second is not"
    assert_equal 1, set.count
  end

  # A piece count that is not a multiple of eight leaves spare bits in the last byte. The
  # last real index has to be reachable and the spare bits have to stay clear.
  test "the last bit of a set that does not fill its final byte" do
    set = Game::Damage::PieceSet.new(20)
    set.add(19)

    assert_equal 3, set.to_blob.bytesize
    assert_equal [ 19 ], set.to_a
    assert_equal "\x00\x00\x08".b, set.to_blob
  end

  test "a blob round trips" do
    set = Game::Damage::PieceSet.new(1454)
    [ 0, 1, 63, 64, 1453 ].each { |index| set.add(index) }

    restored = Game::Damage::PieceSet.from_blob(set.to_blob, 1454)

    assert_equal set.to_a, restored.to_a
    assert_equal set.count, restored.count
  end

  # Without this a malformed index writes into the bytes of a neighbouring object's bitset.
  test "an index outside the object is refused" do
    set = Game::Damage::PieceSet.new(20)

    assert_raises(ArgumentError) { set.add(20) }
    assert_raises(ArgumentError) { set.add(-1) }
    assert_raises(ArgumentError) { set.include?(20) }
  end

  test "a short blob is padded rather than trusted" do
    restored = Game::Damage::PieceSet.from_blob("\xFF".b, 20)

    assert_equal (0..7).to_a, restored.to_a
    assert_equal 3, restored.to_blob.bytesize
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/game/damage/piece_set_test.rb`
Expected: FAIL — `NameError: uninitialized constant Game::Damage::PieceSet`

- [ ] **Step 3: Write minimal implementation**

```ruby
module Game
  module Damage
    # Which pieces of one object are gone, as a bitset.
    #
    # This is what makes a city's worth of destruction storable. A thousand-piece building
    # is 125 bytes here; as rows it would be a thousand of them, and a thousand buildings
    # would be a quarter of a million. The column is the reason the piece is not a record.
    #
    # Byte `index / 8`, bit `index % 8`, least significant bit first. The ordering is
    # arbitrary and must never change -- it is what a stored blob means, and every bitset
    # already written down assumes it.
    class PieceSet
      attr_reader :size

      def self.from_blob(blob, size)
        new(size).tap { |set| set.replace(blob) }
      end

      def initialize(size)
        @size = size.to_i
        @bytes = Array.new(byte_length, 0)
      end

      def replace(blob)
        bytes = (blob || "").b.bytes
        @bytes = Array.new(byte_length) { |i| bytes[i] || 0 }
      end

      def add(index)
        check!(index)
        return false if include?(index)

        @bytes[index / 8] |= (1 << (index % 8))
        true
      end

      def include?(index)
        check!(index)
        @bytes[index / 8].anybits?(1 << (index % 8))
      end

      def count
        @bytes.sum { |byte| byte.to_s(2).count("1") }
      end

      def to_a
        (0...size).select { |index| include?(index) }
      end

      def to_blob
        @bytes.pack("C*")
      end

      private
        def byte_length = (size / 8.0).ceil

        def check!(index)
          return if index.is_a?(Integer) && index >= 0 && index < size

          raise ArgumentError, "piece #{index} is outside this object's #{size} pieces"
        end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/models/game/damage/piece_set_test.rb`
Expected: PASS, 7 runs 0 failures

- [ ] **Step 5: Commit**

```bash
bin/rubocop app/models/game/damage/piece_set.rb test/models/game/damage/piece_set_test.rb
git add app/models/game/damage/piece_set.rb test/models/game/damage/piece_set_test.rb
git commit -m "Store what is broken as bits rather than rows"
```

---

### Task 2: `Game::Damage::ObjectState` — one object's damage

Maps 1:1 onto an `object_damages` row: the bitset, the part-damaged pieces, and
`collapsed_from`. Pure Ruby — it is handed a `SurfaceSet` and never looks a row up.

**Files:**
- Create: `app/models/game/damage/object_state.rb`
- Test: `test/models/game/damage/object_state_test.rb`

**Interfaces:**
- Consumes: `PieceSet` (Task 1), `Game::Damage::Collapse.evaluate` (built), `Game::Materials`.
- Produces:
  - `ObjectState.new(surfaces:, piece_count:, rules:, destroyed: nil, partial: {}, collapsed_from: nil)`
    where `rules` is the whole `Game::Spec.default_rules` hash.
  - `#apply(piece_index, raw, kind)` → Array of piece indices this hit broke (`[]` or `[index]`).
    Returns `[]` for an out-of-range index rather than raising — a malformed index from the
    wire is a client bug, not a server crash.
  - `#settle` → `Game::Damage::Collapse::Result`-shaped outcome applied to self; returns the
    new `collapsed_from` (Integer) or `nil`. Also returns nothing new if already collapsed lower.
  - `#broken` → Array of destroyed piece indices
  - `#standing?(piece_index)` → Boolean
  - `#collapsed_from` → Integer or nil
  - `#destroyed_blob` → binary String, `#partial` → Hash, `#destroyed_count` → Integer
  - `#dirty?` / `#clean!` — whether anything changed since the last flush

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"

class Game::Damage::ObjectStateTest < ActiveSupport::TestCase
  def house
    Game::Building::Generator.call({
      footprint: [ [ 0, 0 ], [ 12, 0 ], [ 12, 15 ], [ 0, 15 ] ],
      storeys: 3, storey_height: 3.0, eaves: 9.0, ridge: 12.75,
      roof: "gable", cell: 1.0, seed: 7
    })
  end

  def state(set = house, **options)
    Game::Damage::ObjectState.new(
      surfaces: set, piece_count: set.piece_count,
      rules: Game::Spec.default_rules, **options
    )
  end

  # A brick cell at this size is worth 4.38 health, so a small knock dents it and a big
  # one takes it out. The server runs the same absorb the client does, from the same table.
  test "a small hit dents a piece without breaking it" do
    object = state

    assert_empty object.apply(0, 2.0, "impact")
    assert object.standing?(0)
    assert_predicate object.partial, :any?
  end

  test "enough damage breaks the piece" do
    object = state

    assert_equal [ 0 ], object.apply(0, 500.0, "impact")
    refute object.standing?(0)
    assert_equal [ 0 ], object.broken
  end

  test "damage accumulates across separate hits" do
    object = state
    4.times { object.apply(0, 2.0, "impact") }

    refute object.standing?(0), "four dents should have finished it"
  end

  # Monotone: the piece is already gone, so a later hit is a no-op rather than a second
  # break event that every client would apply twice.
  test "a broken piece cannot break again" do
    object = state
    object.apply(0, 500.0, "impact")

    assert_empty object.apply(0, 500.0, "impact")
  end

  # Without the bounds check a malformed index writes into another object's bitset.
  test "an index outside the object is ignored rather than fatal" do
    object = state

    assert_empty object.apply(999_999, 500.0, "impact")
    assert_empty object.apply(-1, 500.0, "impact")
    assert_empty object.broken
  end

  test "the material decides what a hit is worth" do
    set = house
    object = state(set)
    glass = (0...set.piece_count).find { |i| set.material_at(i)&.name == :glass }
    skip "no glass in the canonical house" unless glass

    assert_equal [ glass ], object.apply(glass, 3.0, "impact"),
                 "glass should go on a knock that only dents brick"
  end

  test "settle brings a storey down once its walls are gone" do
    set = house
    object = state(set)
    walls = set.for_storey(0).select { |s| s.kind == :wall }.first(2)
    walls.each do |surface|
      (surface.piece_offset...(surface.piece_offset + surface.piece_count)).each do |index|
        object.apply(index, 500.0, "impact")
      end
    end

    assert_equal 0, object.settle
    assert_equal 0, object.collapsed_from
    refute object.standing?(set.piece_count - 1), "the roof should have come down too"
  end

  test "settle reports nothing when the building still stands" do
    assert_nil state.settle
  end

  test "collapsed_from is never raised" do
    set = house
    object = state(set, collapsed_from: 0)
    set.surfaces.select { |s| s.storey >= 1 }.each do |surface|
      (surface.piece_offset...(surface.piece_offset + surface.piece_count)).each do |index|
        object.apply(index, 500.0, "impact")
      end
    end

    object.settle
    assert_equal 0, object.collapsed_from
  end

  test "it restores from the columns it was stored in" do
    set = house
    stored = state(set)
    stored.apply(0, 500.0, "impact")
    stored.apply(1, 2.0, "impact")

    restored = Game::Damage::ObjectState.new(
      surfaces: set, piece_count: set.piece_count, rules: Game::Spec.default_rules,
      destroyed: stored.destroyed_blob, partial: stored.partial, collapsed_from: nil
    )

    assert_equal stored.broken, restored.broken
    refute restored.standing?(0)
    assert_in_delta stored.partial[1], restored.partial[1], 1e-9
  end

  test "it knows whether it has anything worth writing down" do
    object = state

    refute_predicate object, :dirty?
    object.apply(0, 500.0, "impact")
    assert_predicate object, :dirty?
    object.clean!
    refute_predicate object, :dirty?
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/game/damage/object_state_test.rb`
Expected: FAIL — `NameError: uninitialized constant Game::Damage::ObjectState`

- [ ] **Step 3: Write minimal implementation**

Note `partial` keys: JSON columns come back with String keys, so normalise to Integer on the
way in and let `#partial` hand back Integer keys.

```ruby
module Game
  module Damage
    # What one match has done to one object, in memory. Mirrors an object_damages row
    # exactly: the bitset of what is gone, the part-damaged pieces, and how far down the
    # building has collapsed.
    #
    # The server does not simulate, so it cannot work out on its own what a car did. It
    # takes the client's word for the raw damage and applies the material's own arithmetic
    # to it -- the same absorb the client ran -- so hardness and multipliers are enforced
    # here even though the impact was not. That is the accepted price of clients reporting
    # damage, and the caps in MatchState are what bound it.
    class ObjectState
      attr_reader :collapsed_from, :partial

      def initialize(surfaces:, piece_count:, rules:, destroyed: nil, partial: {}, collapsed_from: nil)
        @surfaces = surfaces
        @piece_count = piece_count.to_i
        @rules = rules
        @destroyed = PieceSet.from_blob(destroyed, @piece_count)
        @partial = (partial || {}).to_h { |index, left| [ index.to_i, left.to_f ] }
        @collapsed_from = collapsed_from
        @dirty = false
      end

      # Returns the piece indices this hit broke. An index the object does not have is
      # dropped rather than raised: it is a malformed message, and a channel is not the
      # place to crash.
      def apply(piece_index, raw, kind)
        return [] unless piece_index.is_a?(Integer) && piece_index >= 0 && piece_index < @piece_count
        return [] unless standing?(piece_index)

        material = @surfaces.material_at(piece_index)
        return [] if material.nil? || !material.structural? && material.name == :void

        amount = material.absorb(raw.to_f * material.multiplier_for(kind), minimum_fraction)
        return [] if amount <= 0

        left = remaining(piece_index, material) - amount
        @dirty = true

        if left > 0
          @partial[piece_index] = left
          []
        else
          destroy!(piece_index)
          [ piece_index ]
        end
      end

      # Runs the collapse rule over what is left. Returns the storey it came down from, or
      # nil. Everything the collapse destroyed is folded into this object's own state, so
      # the caller only has to broadcast the storey.
      def settle
        result = Collapse.evaluate(
          surfaces: @surfaces, broken: @destroyed.to_a, health: @partial,
          rules: @rules.fetch(:collapse), collapsed_from: @collapsed_from
        )
        return nil if result.collapsed_from == @collapsed_from

        result.broken.each { |index| destroy!(index) }
        @partial = result.health.except(*result.broken)
        @collapsed_from = result.collapsed_from
        @dirty = true
        @collapsed_from
      end

      def standing?(piece_index) = !@destroyed.include?(piece_index)
      def broken = @destroyed.to_a
      def destroyed_blob = @destroyed.to_blob
      def destroyed_count = @destroyed.count
      def dirty? = @dirty
      def clean! = @dirty = false

      private
        def minimum_fraction = @rules.fetch(:damage).fetch(:minimum_fraction, 0.0)

        def remaining(piece_index, material)
          @partial.fetch(piece_index) do
            surface, row, col = @surfaces.at(piece_index)
            material.health_for(surface.cell_area, surface.thickness).tap { row; col }
          end
        end

        def destroy!(piece_index)
          @destroyed.add(piece_index)
          @partial.delete(piece_index)
        end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/models/game/damage/object_state_test.rb`
Expected: PASS, 11 runs 0 failures

- [ ] **Step 5: Commit**

```bash
bin/rubocop app/models/game/damage/object_state.rb test/models/game/damage/object_state_test.rb
git add app/models/game/damage/object_state.rb test/models/game/damage/object_state_test.rb
git commit -m "Keep one object's wreckage, and let it settle"
```

---

### Task 3: `Game::Damage::MatchState` — every object in a match

**Files:**
- Create: `app/models/game/damage/match_state.rb`
- Test: `test/models/game/damage/match_state_test.rb`

**Interfaces:**
- Consumes: `ObjectState` (Task 2), `Match`, `WorldObject`, `ObjectDamage`.
- Produces:
  - `MatchState.new(match, rules:)` — `match` is a `Match` record
  - `#apply_batch(hits)` where `hits` is `[[object_id, piece_index, amount, kind], …]`
    → `{ "broken" => [[object_id, piece_index], …], "collapses" => [[object_id, storey], …] }`
  - `#state_for(object_ids)` → `[{ "id" =>, "destroyed" => Base64 String, "collapsed_from" => }, …]`
  - `#flush!` → writes every dirty object to `object_damages`, returns the number written
  - `#rehydrate!` → loads existing `object_damages` rows into memory
  - `MatchState::MAX_HITS_PER_BATCH = 512`, `MatchState::MAX_AMOUNT_PER_HIT = 5_000.0`

This is the one class here that touches the database, so it lives under `game/` only because
it is handed records rather than finding them. It takes a `Match` and reads through its
associations; it never queries by slug or key.

Caps are honest about what they are: they bound a cheating client's blast radius, they are
not security. The server cannot recompute damage without simulating.

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"

class Game::Damage::MatchStateTest < ActiveSupport::TestCase
  setup do
    @world = World.find_by!(slug: "targets")
    @match = Match.start(key: "test-match", world: @world)
    @house = @world.world_objects.find_by!(kind: "building")
    @state = Game::Damage::MatchState.new(@match, rules: Game::Spec.default_rules)
  end

  def wall_indices(count)
    set = @house.surface_set
    set.for_storey(0).select { |s| s.kind == :wall }.first(count).flat_map do |surface|
      (surface.piece_offset...(surface.piece_offset + surface.piece_count)).to_a
    end
  end

  test "a hit that breaks a piece is reported back" do
    result = @state.apply_batch([ [ @house.id, 0, 500.0, "impact" ] ])

    assert_equal [ [ @house.id, 0 ] ], result["broken"]
    assert_empty result["collapses"]
  end

  test "a hit that only dents reports nothing" do
    result = @state.apply_batch([ [ @house.id, 0, 1.0, "impact" ] ])

    assert_empty result["broken"]
  end

  test "an unknown object is ignored" do
    result = @state.apply_batch([ [ 999_999, 0, 500.0, "impact" ] ])

    assert_empty result["broken"]
  end

  test "taking out two walls reports the collapse" do
    hits = wall_indices(2).map { |index| [ @house.id, index, 500.0, "impact" ] }

    result = @state.apply_batch(hits)

    assert_equal [ [ @house.id, 0 ] ], result["collapses"]
  end

  # Not security -- the server cannot recompute damage without simulating -- but it bounds
  # what one malformed or malicious batch can reach.
  test "an over-long batch is truncated" do
    hits = Array.new(Game::Damage::MatchState::MAX_HITS_PER_BATCH + 50) { [ @house.id, 0, 0.1, "impact" ] }

    assert_nothing_raised { @state.apply_batch(hits) }
  end

  test "a single hit cannot exceed the per-hit cap" do
    huge = Game::Damage::MatchState::MAX_AMOUNT_PER_HIT * 1000
    @state.apply_batch([ [ @house.id, 0, huge, "impact" ] ])

    capped = Game::Damage::MatchState.new(@match, rules: Game::Spec.default_rules)
    capped.apply_batch([ [ @house.id, 0, Game::Damage::MatchState::MAX_AMOUNT_PER_HIT, "impact" ] ])

    assert_equal capped.state_for([ @house.id ]).first["destroyed"],
                 @state.state_for([ @house.id ]).first["destroyed"]
  end

  test "a malformed hit is dropped rather than fatal" do
    assert_nothing_raised do
      @state.apply_batch([ [ @house.id, "not-an-index", 5.0, "impact" ], nil, [ @house.id ] ])
    end
  end

  test "flushing writes a row and rehydrating reads it back" do
    @state.apply_batch([ [ @house.id, 0, 500.0, "impact" ] ])

    assert_equal 1, @state.flush!

    row = ObjectDamage.find_by!(match: @match, world_object: @house)
    assert_equal 1, row.destroyed_count

    fresh = Game::Damage::MatchState.new(@match, rules: Game::Spec.default_rules)
    fresh.rehydrate!

    assert_empty fresh.apply_batch([ [ @house.id, 0, 500.0, "impact" ] ])["broken"],
                 "piece 0 was already broken before the restart"
    assert_equal 1, fresh.state_for([ @house.id ]).first["destroyed_count"]
  end

  test "flushing twice writes nothing the second time" do
    @state.apply_batch([ [ @house.id, 0, 500.0, "impact" ] ])
    @state.flush!

    assert_equal 0, @state.flush!, "nothing changed, so nothing should be written"
  end

  test "state_for hands back what a joining client needs" do
    @state.apply_batch([ [ @house.id, 0, 500.0, "impact" ] ])

    entry = @state.state_for([ @house.id ]).first

    assert_equal @house.id, entry["id"]
    assert_equal 1, entry["destroyed_count"]
    assert_nil entry["collapsed_from"]
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/game/damage/match_state_test.rb`
Expected: FAIL — `NameError: uninitialized constant Game::Damage::MatchState`

- [ ] **Step 3: Write minimal implementation**

```ruby
module Game
  module Damage
    # Every object one match has damaged, held in memory and written down occasionally.
    #
    # Play never waits on SQLite. A batch lands in memory, the answer goes straight back
    # out over the socket, and the rows catch up about once a second -- so the worst a
    # process restart costs is a second of wreckage, and the client's monotone state makes
    # even that invisible.
    class MatchState
      # Bounds on what one batch can reach. Be honest about these: they are not security.
      # The server cannot recompute damage without simulating, which is the accepted price
      # of clients reporting it. They bound the blast radius, nothing more.
      MAX_HITS_PER_BATCH = 512
      MAX_AMOUNT_PER_HIT = 5_000.0

      def initialize(match, rules:)
        @match = match
        @rules = rules
        @objects = {}
        @loaded = false
      end

      def apply_batch(hits)
        broken = []
        touched = {}

        Array(hits).first(MAX_HITS_PER_BATCH).each do |hit|
          object_id, piece_index, amount, kind = hit
          next unless hit.is_a?(Array) && hit.length >= 3

          state = state_of(object_id)
          next unless state

          capped = [ amount.to_f, MAX_AMOUNT_PER_HIT ].min
          state.apply(cast_index(piece_index), capped, (kind || "impact").to_s).each do |index|
            broken << [ object_id.to_i, index ]
            touched[object_id.to_i] = state
          end
        end

        collapses = touched.filter_map do |object_id, state|
          storey = state.settle
          storey && [ object_id, storey ]
        end

        { "broken" => broken, "collapses" => collapses }
      end

      def state_for(object_ids)
        Array(object_ids).filter_map do |object_id|
          state = state_of(object_id)
          next unless state

          {
            "id" => object_id.to_i,
            "destroyed" => Base64.strict_encode64(state.destroyed_blob),
            "destroyed_count" => state.destroyed_count,
            "collapsed_from" => state.collapsed_from
          }
        end
      end

      def rehydrate!
        ObjectDamage.where(match: @match).find_each do |row|
          object = objects_by_id[row.world_object_id]
          next unless object

          @objects[row.world_object_id] = build_state(object, row)
        end
        @loaded = true
      end

      # One statement, inside an IMMEDIATE transaction. SQLite's classic deadlock is two
      # deferred transactions each taking a read lock and then both trying to upgrade;
      # taking the write lock at BEGIN removes the upgrade and therefore the deadlock.
      def flush!
        dirty = @objects.select { |_, state| state.dirty? }
        return 0 if dirty.empty?

        now = Time.current
        rows = dirty.map do |object_id, state|
          {
            match_id: @match.id, world_object_id: object_id,
            destroyed: state.destroyed_blob, partial: state.partial,
            collapsed_from: state.collapsed_from, destroyed_count: state.destroyed_count,
            updated_at: now
          }
        end

        ApplicationRecord.transaction(isolation: :immediate) do
          ObjectDamage.upsert_all(rows, unique_by: %i[match_id world_object_id])
        end

        dirty.each_value(&:clean!)
        rows.length
      end

      private
        def cast_index(value) = value.is_a?(Integer) ? value : -1

        def state_of(object_id)
          id = object_id.to_i
          return @objects[id] if @objects.key?(id)

          object = objects_by_id[id]
          return nil unless object&.building?

          @objects[id] = build_state(object, nil)
        end

        def build_state(object, row)
          ObjectState.new(
            surfaces: object.surface_set, piece_count: object.piece_count, rules: @rules,
            destroyed: row&.destroyed, partial: row&.partial || {},
            collapsed_from: row&.collapsed_from
          )
        end

        def objects_by_id
          @objects_by_id ||= @match.world.world_objects.index_by(&:id)
        end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/models/game/damage/match_state_test.rb`
Expected: PASS, 11 runs 0 failures

- [ ] **Step 5: Commit**

```bash
bin/rubocop app/models/game/damage/match_state.rb test/models/game/damage/match_state_test.rb
git add app/models/game/damage/match_state.rb test/models/game/damage/match_state_test.rb
git commit -m "Hold a match's wreckage in memory and write it down occasionally"
```

---

### Task 4: `Game::Damage::Registry` — one state per match, per process

**Files:**
- Create: `app/models/game/damage/registry.rb`
- Test: `test/models/game/damage/registry_test.rb`

**Interfaces:**
- Consumes: `MatchState` (Task 3), `Match`.
- Produces:
  - `Registry.checkout(match) { |state| … }` — yields the `MatchState` under that match's own
    `Monitor`, rehydrating on first use. Returns the block's value. Flushes if more than
    `FLUSH_EVERY` seconds have passed since the last flush.
  - `Registry.release(match)` — flushes and drops the state. Called on last unsubscribe.
  - `Registry.reset!` — test hook; drops everything without flushing.
  - `Registry::FLUSH_EVERY = 1.0`

`config/puma.rb` has no `workers` line, so there is one process today and the registry is
correct by construction. Task 5 adds the authority claim that makes that *enforced* rather
than merely true.

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"

class Game::Damage::RegistryTest < ActiveSupport::TestCase
  setup do
    Game::Damage::Registry.reset!
    @world = World.find_by!(slug: "targets")
    @match = Match.start(key: "registry-test", world: @world)
    @house = @world.world_objects.find_by!(kind: "building")
  end

  teardown { Game::Damage::Registry.reset! }

  test "the same match gets the same state back" do
    first = Game::Damage::Registry.checkout(@match) { |state| state.object_id }
    second = Game::Damage::Registry.checkout(@match) { |state| state.object_id }

    assert_equal first, second
  end

  test "different matches do not share wreckage" do
    other = Match.start(key: "registry-other", world: @world)

    Game::Damage::Registry.checkout(@match) do |state|
      state.apply_batch([ [ @house.id, 0, 500.0, "impact" ] ])
    end
    broken = Game::Damage::Registry.checkout(other) do |state|
      state.state_for([ @house.id ]).first["destroyed_count"]
    end

    assert_equal 0, broken, "one match's damage must not show up in another"
  end

  test "releasing writes the wreckage down" do
    Game::Damage::Registry.checkout(@match) do |state|
      state.apply_batch([ [ @house.id, 0, 500.0, "impact" ] ])
    end

    Game::Damage::Registry.release(@match)

    assert_equal 1, ObjectDamage.where(match: @match).count
  end

  test "a released match comes back from its rows" do
    Game::Damage::Registry.checkout(@match) do |state|
      state.apply_batch([ [ @house.id, 0, 500.0, "impact" ] ])
    end
    Game::Damage::Registry.release(@match)

    count = Game::Damage::Registry.checkout(@match) do |state|
      state.state_for([ @house.id ]).first["destroyed_count"]
    end

    assert_equal 1, count
  end

  # Two threads hammering the same match must not interleave inside a batch.
  test "concurrent checkouts do not lose damage" do
    threads = 4.times.map do |n|
      Thread.new do
        Game::Damage::Registry.checkout(@match) do |state|
          state.apply_batch([ [ @house.id, n, 500.0, "impact" ] ])
        end
      end
    end
    threads.each(&:join)

    count = Game::Damage::Registry.checkout(@match) do |state|
      state.state_for([ @house.id ]).first["destroyed_count"]
    end

    assert_operator count, :>=, 4, "every thread's break should have landed"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/game/damage/registry_test.rb`
Expected: FAIL — `NameError: uninitialized constant Game::Damage::Registry`

- [ ] **Step 3: Write minimal implementation**

```ruby
module Game
  module Damage
    # The live wreckage of every match this process is running, one MatchState each behind
    # its own Monitor.
    #
    # Process-global on purpose. Destruction is authoritative in exactly one process --
    # config/puma.rb has no `workers` line, so that is true by construction today, and
    # ArenaChannel's authority claim is what makes it enforced rather than merely true.
    module Registry
      FLUSH_EVERY = 1.0

      @monitor = Monitor.new
      @states = {}
      @locks = {}
      @flushed_at = {}

      class << self
        def checkout(match)
          lock = lock_for(match.id)

          lock.synchronize do
            state = state_for(match)
            result = yield state
            flush_if_due(match.id, state)
            result
          end
        end

        def release(match)
          lock = lock_for(match.id)

          lock.synchronize do
            @monitor.synchronize do
              @states.delete(match.id)&.flush!
              @flushed_at.delete(match.id)
            end
          end
          @monitor.synchronize { @locks.delete(match.id) }
        end

        def reset!
          @monitor.synchronize do
            @states.clear
            @locks.clear
            @flushed_at.clear
          end
        end

        private
          def lock_for(match_id)
            @monitor.synchronize { @locks[match_id] ||= Monitor.new }
          end

          def state_for(match)
            @monitor.synchronize do
              @states[match.id] ||= MatchState.new(match, rules: Spec.default_rules).tap(&:rehydrate!)
            end
          end

          # Debounced rather than scheduled: a thread per match to write a row once a
          # second is a thread per match to own, and the only moment a flush is worth
          # anything is just after something changed.
          def flush_if_due(match_id, state)
            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            last = @monitor.synchronize { @flushed_at[match_id] }
            return if last && now - last < FLUSH_EVERY

            state.flush!
            @monitor.synchronize { @flushed_at[match_id] = now }
          end
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/models/game/damage/registry_test.rb`
Expected: PASS, 5 runs 0 failures

- [ ] **Step 5: Commit**

```bash
bin/rubocop app/models/game/damage/registry.rb test/models/game/damage/registry_test.rb
git add app/models/game/damage/registry.rb test/models/game/damage/registry_test.rb
git commit -m "Keep one live match state per match, behind its own lock"
```

---

### Task 5: `ArenaChannel` — damage in, breaks out

**Files:**
- Modify: `app/channels/arena_channel.rb`
- Modify: `test/models/game/arena_channel_test.rb`

**Interfaces:**
- Consumes: `Registry` (Task 4), `Match#claim` (already built).
- Produces, client → server:
  - `damage` `{ "seq" =>, "hits" => [[object_id, piece_index, amount, kind], …] }`
  - `request_state` `{ "ids" => [object_id, …] }`
- Produces, server → client:
  - `breaks` `{ "type" => "breaks", "broken" => [...], "collapses" => [...], "authority" => }`
    — **broadcast without a `player_id`**, so the sender receives it too. `NetConnection`
    drops messages stamped with its own id, and a collapse has to reach the client that
    caused it.
  - `state` `{ "type" => "state", "objects" => [...], "authority" => }` — `transmit`ted to the
    one subscriber that asked, not broadcast.
  - `error` `{ "type" => "error", "reason" => "not_authoritative" }` — `transmit`ted.

The world a match belongs to comes from `params[:world]`, matching what the page was served
with. A match whose key already exists keeps its original world.

- [ ] **Step 1: Write the failing test**

Append to `test/models/game/arena_channel_test.rb`:

```ruby
  test "damage comes back as breaks" do
    world = World.find_by!(slug: "targets")
    house = world.world_objects.find_by!(kind: "building")
    subscribe(match: "damage-test", world: "targets")

    broadcast = capture_broadcast("arena:damage-test") do
      perform :damage, "seq" => 1, "hits" => [ [ house.id, 0, 500.0, "impact" ] ]
    end

    assert_equal "breaks", broadcast["type"]
    assert_equal [ [ house.id, 0 ] ], broadcast["broken"]
  end

  # The sender has to receive this one. NetConnection drops anything stamped with its own
  # player_id, and a collapse the client did not predict would be dropped with it.
  test "breaks are not stamped with the sender" do
    world = World.find_by!(slug: "targets")
    house = world.world_objects.find_by!(kind: "building")
    subscribe(match: "damage-stamp", world: "targets")

    broadcast = capture_broadcast("arena:damage-stamp") do
      perform :damage, "seq" => 1, "hits" => [ [ house.id, 0, 500.0, "impact" ] ]
    end

    assert_nil broadcast["player_id"]
    assert broadcast["authority"].present?, "every breaks message says who decided it"
  end

  test "a batch that changes nothing broadcasts nothing" do
    subscribe(match: "damage-quiet", world: "targets")

    assert_no_broadcasts("arena:damage-quiet") do
      perform :damage, "seq" => 1, "hits" => []
    end
  end

  test "damage without a world is refused" do
    subscribe(match: "damage-worldless")

    assert_no_broadcasts("arena:damage-worldless") do
      perform :damage, "seq" => 1, "hits" => [ [ 1, 0, 500.0, "impact" ] ]
    end
  end

  test "request_state answers the asker alone" do
    world = World.find_by!(slug: "targets")
    house = world.world_objects.find_by!(kind: "building")
    subscribe(match: "state-test", world: "targets")
    perform :damage, "seq" => 1, "hits" => [ [ house.id, 0, 500.0, "impact" ] ]

    perform :request_state, "ids" => [ house.id ]

    reply = transmissions.last
    assert_equal "state", reply["type"]
    assert_equal 1, reply["objects"].first["destroyed_count"]
  end
```

Add to the top of the file, alongside the existing `setup`:

```ruby
  teardown { Game::Damage::Registry.reset! }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/game/arena_channel_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'damage'` / unknown action

- [ ] **Step 3: Write minimal implementation**

```ruby
# Relays vehicle snapshots between players in a match, and is the authority on what that
# match has destroyed.
#
# Two halves with deliberately different rules. Vehicles are relayed and never simulated --
# each client owns its own car, and the server stamping identity is the whole of its job.
# Destruction is the opposite: clients report what they hit and the server decides what
# that did, because a collapse follows from the sum of what everyone has done and no
# client can see that sum.
class ArenaChannel < ApplicationCable::Channel
  DEFAULT_MATCH = "lobby".freeze
  # Which process holds a match. One per boot, so a restart looks like a new claimant.
  AUTHORITY = "#{Socket.gethostname}-#{Process.pid}-#{SecureRandom.hex(4)}".freeze

  def subscribed
    @match = sanitised_match(params[:match])
    @world = World.find_by(slug: params[:world].to_s)
    @record = Match.start(key: @match, world: @world) if @world
    @authoritative = @record ? @record.claim(AUTHORITY) : false
    stream_from stream_name

    broadcast(type: "join")
  end

  def unsubscribed
    broadcast(type: "leave")
    Game::Damage::Registry.release(@record) if @record
  end

  # Snapshots arrive ~20Hz per client. Everything is relayed verbatim except player_id,
  # which is stamped here rather than trusted from the payload.
  def snapshot(data)
    broadcast(
      type: "snapshot",
      vehicle: data["vehicle"],
      t: data["t"],
      p: data["p"],
      q: data["q"],
      v: data["v"],
      w: data["w"],
      f: data["f"]
    )
  end

  # What a client says it hit. Applied here, not recomputed -- the server does not
  # simulate. What comes back is authoritative and monotone, so a client that already
  # predicted a break simply sees it confirmed.
  def damage(data)
    return unless @record
    return transmit(type: "error", reason: "not_authoritative") unless @authoritative

    result = Game::Damage::Registry.checkout(@record) do |state|
      state.apply_batch(data["hits"])
    end
    return if result["broken"].empty? && result["collapses"].empty?

    # Deliberately NOT stamped with player_id: NetConnection drops its own echo, and the
    # client that caused a collapse is exactly the one that most needs to hear about it.
    ActionCable.server.broadcast(stream_name, {
      "type" => "breaks", "authority" => AUTHORITY,
      "broken" => result["broken"], "collapses" => result["collapses"]
    })
  end

  # Sent alongside a chunk fetch: what is already broken of the objects just loaded.
  # Answered to the asker alone rather than broadcast -- nobody else asked.
  def request_state(data)
    return unless @record

    objects = Game::Damage::Registry.checkout(@record) do |state|
      state.state_for(data["ids"])
    end

    transmit(type: "state", authority: AUTHORITY, objects: objects)
  end

  private
    def broadcast(payload)
      ActionCable.server.broadcast(stream_name, payload.merge(player_id: player_id))
    end

    def stream_name
      "arena:#{@match}"
    end

    def sanitised_match(value)
      candidate = value.to_s.strip
      return DEFAULT_MATCH unless candidate.match?(/\A[a-zA-Z0-9_-]{1,32}\z/)

      candidate
    end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/models/game/arena_channel_test.rb`
Expected: PASS, all runs 0 failures

- [ ] **Step 5: Pass the world through to the subscription**

Modify `app/views/arenas/show.html.erb` to add `data-arena-world-value="<%= @world_record.slug %>"`,
`app/javascript/controllers/arena_controller.js` to add `world: String` to `static values` and
pass `world: this.worldValue` into `GameEngine`, and `app/javascript/game/engine.js` to accept
and store `world`.

- [ ] **Step 6: Commit**

```bash
bin/rubocop app/channels/arena_channel.rb test/models/game/arena_channel_test.rb
bin/rails test
git add app/channels/arena_channel.rb test/models/game/arena_channel_test.rb app/views/arenas/show.html.erb app/javascript/controllers/arena_controller.js app/javascript/game/engine.js
git commit -m "Let a match say what it has lost, and who is saying so"
```

---

### Task 6: Client reports what it broke

**Files:**
- Create: `app/javascript/game/net/damage_reporter.js`
- Modify: `app/javascript/game/world/building.js` (emit an `onBreak` callback)
- Modify: `app/javascript/game/world/buildings.js` (thread the callback through)

**Interfaces:**
- Consumes: `NetConnection` (exists, unimported).
- Produces:
  - `new DamageReporter({ connection, hz })`
  - `#report(objectId, pieceIndex, raw, kind)` — queues one cell
  - `#update(dt)` — flushes the queue at `hz`
  - `NetConnection#sendDamage(payload)` and `#requestState(ids)` — added to the existing class

The client reports the **raw** damage per cell, after its own spread and block expansion but
before absorb, because that is what `ObjectState#apply` expects. Reporting post-absorb would
apply the material twice; reporting only the hit centre would mean porting spread and block
to the server.

- [ ] **Step 1: Write the failing test**

There is no JS unit harness in this repo, so this task's test is the system test in Task 9.
Instead, verify by hand in this task and lean on Task 9 for the regression net. Add the
reporter with a `window.__arenaReported` counter so Task 9 can assert on it:

```javascript
window.__arenaReported = () => this.reporter?.sent ?? 0
```

- [ ] **Step 2: Add `sendDamage` and `requestState` to `NetConnection`**

```javascript
  sendDamage(payload) {
    if (!this.connected) return false
    this.subscription.perform("damage", payload)
    return true
  }

  requestState(ids) {
    if (!this.connected) return false
    this.subscription.perform("request_state", { ids })
    return true
  }
```

- [ ] **Step 3: Write the reporter**

```javascript
// Batches the cells this client has broken and tells the server about them.
//
// Batched rather than sent per cell: one impact with spread can touch a dozen cells, and a
// dozen socket frames per hit is how a burst of rocket fire turns into a stall. The rate is
// the same snapshot_hz the vehicle relay already runs at.
//
// What is reported is the RAW damage per cell -- after this client's own spread and block
// expansion, before the material has had its say. The server runs the same absorb against
// the same table. Reporting the absorbed figure would apply the material twice; reporting
// only the cell that was touched would mean porting spread and blocks to the server.
export class DamageReporter {
  constructor({ connection, hz = 20 }) {
    this.connection = connection
    this.interval = 1 / hz
    this.elapsed = 0
    this.queue = []
    this.seq = 0
    this.sent = 0
  }

  report(objectId, pieceIndex, raw, kind = "impact") {
    if (objectId === undefined || objectId === null) return
    this.queue.push([ objectId, pieceIndex, raw, kind ])
  }

  update(dt) {
    this.elapsed += dt
    if (this.elapsed < this.interval) return
    this.elapsed = 0
    if (this.queue.length === 0) return

    const hits = this.queue
    this.queue = []
    if (this.connection?.sendDamage({ seq: ++this.seq, hits })) this.sent += hits.length
  }
}
```

- [ ] **Step 4: Emit breaks from `Building`**

In `building.js`, accept `onDamage` in the constructor and store it. In `damageCell`, after
computing `amount` and before mutating health, call:

```javascript
    this.onDamage?.(this.id, index, raw, kind)
```

Report `raw`, not `amount` — the server absorbs. Thread `onDamage` through `Buildings`'
constructor into each `Building`.

- [ ] **Step 5: Verify by hand**

```bash
bin/dev
```

Open `http://localhost:<port>/?world=targets&vehicle=buggy`, drive into the house, and confirm
in the browser console that `__arenaReported()` climbs.

- [ ] **Step 6: Commit**

```bash
git add app/javascript/game/net/damage_reporter.js app/javascript/game/net/connection.js app/javascript/game/world/building.js app/javascript/game/world/buildings.js
git commit -m "Tell the server what this client knocked down"
```

---

### Task 7: Client applies what the server says

**Files:**
- Modify: `app/javascript/game/world/buildings.js` (add `applyBreaks`, `applyCollapse`, `applyState`)
- Modify: `app/javascript/game/engine.js` (wire `NetConnection`, `DamageReporter`, message routing)

**Interfaces:**
- Consumes: Task 5's `breaks` and `state` messages, Task 6's reporter.
- Produces:
  - `Buildings#applyBreaks(broken)` — `broken` is `[[objectId, pieceIndex], …]`
  - `Buildings#applyCollapse(objectId, fromStorey)` — hides every piece whose surface's
    `storey >= fromStorey`
  - `Buildings#applyState(objects)` — `[{ id, destroyed, collapsed_from }]`, destroyed is
    Base64 of the bitset
  - `window.__arenaCollapses` → count of collapses applied, for Task 9

**Monotone:** `applyState` only ever breaks pieces. A piece this client has already broken
that the server says is standing is left broken — one line, and it makes a post-restart
rollback invisible.

- [ ] **Step 1: Add the collapse expansion to `Buildings`**

```javascript
  applyBreaks(broken) {
    for (const [ objectId, pieceIndex ] of broken || []) {
      this.byId.get(objectId)?.break(pieceIndex)
    }
  }

  // Twenty bytes on the wire become a hundred and fifty pieces here. The client already
  // holds the surfaces, so expanding a collapse is a filter rather than a message.
  applyCollapse(objectId, fromStorey) {
    const building = this.byId.get(objectId)
    if (!building) return 0
    return building.collapse(fromStorey)
  }

  applyState(objects) {
    for (const entry of objects || []) {
      const building = this.byId.get(entry.id)
      if (!building) continue
      building.applyDestroyed(entry.destroyed)
      if (entry.collapsed_from !== null && entry.collapsed_from !== undefined) {
        building.collapse(entry.collapsed_from)
      }
    }
  }
```

- [ ] **Step 2: Add `collapse` and `applyDestroyed` to `Building`**

```javascript
  // Everything at or above the failed storey goes. Roof and gables carry storey_count,
  // which is above every real storey, so they come down with it.
  collapse(fromStorey) {
    let count = 0
    for (let index = 0; index < this.pieceCount; index++) {
      const surface = this.spec.surfaces[this.surfaceOf[index]]
      if (!surface || surface.storey < fromStorey) continue
      if (this.breakCell(index)) count++
    }
    return count
  }

  // Monotone: this only ever breaks. A piece we have already broken that the server thinks
  // is standing stays broken -- which is what makes a rollback after a server restart
  // invisible rather than a wall flickering back into existence.
  applyDestroyed(base64) {
    if (!base64) return
    const binary = atob(base64)
    for (let index = 0; index < this.pieceCount; index++) {
      const byte = binary.charCodeAt(index >> 3)
      if (byte & (1 << (index & 7))) this.breakCell(index)
    }
  }
```

- [ ] **Step 3: Wire the connection in `engine.js`**

In the constructor, after `this.buildings` is built:

```javascript
    this.connection = new NetConnection({
      match: this.match, playerId: this.playerId,
      onMessage: (data) => this.onNetMessage(data),
      onStatus: (up) => this.onStatus?.(up ? "connected" : "offline")
    })
    this.reporter = new DamageReporter({ connection: this.connection, hz: spec.rules.snapshot_hz })
```

Pass `world: this.world` into the subscription params (Task 5 Step 5 added it), give
`Buildings` `onDamage: (id, piece, raw, kind) => this.reporter.report(id, piece, raw, kind)`,
call `this.reporter.update(dt)` beside `this.buildings.update(dt)`, and add:

```javascript
  onNetMessage(data) {
    switch (data.type) {
      case "breaks":
        this.buildings.applyBreaks(data.broken)
        for (const [ objectId, storey ] of data.collapses || []) {
          this.buildings.applyCollapse(objectId, storey)
          this.collapsesSeen = (this.collapsesSeen || 0) + 1
        }
        break
      case "state":
        this.buildings.applyState(data.objects)
        break
      case "error":
        console.error(`arena: server refused damage (${data.reason})`)
        break
    }
  }
```

Request state once connected:

```javascript
    this.connection.requestState(this.buildings.list.map((b) => b.id))
```

Add `window.__arenaCollapses = () => this.collapsesSeen ?? 0` alongside the other hooks, and
`this.connection?.dispose()` in `dispose()`.

- [ ] **Step 4: Verify by hand**

```bash
bin/dev
```

Drive the buggy into the house at `?world=targets&vehicle=buggy`, take out two ground-floor
walls, and watch it come down. This is the moment the feature exists.

- [ ] **Step 5: Commit**

```bash
git add app/javascript/game/world/buildings.js app/javascript/game/world/building.js app/javascript/game/engine.js
git commit -m "Bring the house down in the browser when the server says so"
```

---

### Task 8: System test — the round trip

**Files:**
- Create: `test/system/collapse_test.rb`

**Interfaces:**
- Consumes: every task above, plus the existing `__arenaBreak` / `__arenaDamagePiece` hooks.

Uses the piece hooks rather than driving at the house, per CLAUDE.md: the assertion is about
the round trip, not about whether a car can reach a wall in 2.5s.

- [ ] **Step 1: Write the failing test**

```ruby
require "application_system_test_case"

class CollapseTest < ApplicationSystemTestCase
  # The whole round trip in one assertion: the client breaks pieces, tells the server, the
  # server runs a rule that exists nowhere in JavaScript, and the house comes down here.
  test "knocking out two ground floor walls brings the house down" do
    visit_world("targets", vehicle: "buggy")
    wait_for(message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }

    building = page.evaluate_script("window.__arenaBuildingIds()[0]")
    walls = page.evaluate_script(<<~JS, building)
      (() => {
        const b = window.__arenaBuildingSpec(arguments[0])
        return b.surfaces.filter(s => s.kind === "wall" && s.storey === 0).slice(0, 2)
      })()
    JS

    page.execute_script(<<~JS, building, walls)
      const [ id, surfaces ] = [ arguments[0], arguments[1] ]
      for (const s of surfaces) {
        for (let i = s.off; i < s.off + s.cols * s.rows; i++) window.__arenaBreak(i, id)
      }
    JS

    wait_for(timeout: 15, message: "the server never reported a collapse") do
      page.evaluate_script("window.__arenaCollapses()") > 0
    end

    roof_gone = page.evaluate_script(<<~JS, building)
      (() => {
        const b = window.__arenaBuildingSpec(arguments[0])
        const roof = b.surfaces.find(s => s.kind === "roof")
        return window.__arenaPieceState(roof.off, arguments[0]).state === "broken"
      })()
    JS

    assert roof_gone, "the roof should have come down with the storeys below it"
  end

  test "damage survives a reload" do
    visit_world("targets", vehicle: "buggy")
    wait_for(message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }

    building = page.evaluate_script("window.__arenaBuildingIds()[0]")
    page.execute_script("window.__arenaBreak(0, arguments[0])", building)
    wait_for(timeout: 15, message: "the break never reached the server") do
      page.evaluate_script("window.__arenaReported()") > 0
    end
    sleep 1.5

    visit_world("targets", vehicle: "buggy")
    wait_for(message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }

    wait_for(timeout: 15, message: "the wreckage did not come back") do
      page.evaluate_script("window.__arenaPieceState(0, arguments[0])", building)&.dig("state") == "broken"
    end
  end
end
```

- [ ] **Step 2: Add the two hooks the test needs**

In `engine.js`:

```javascript
    window.__arenaBuildingIds = () => this.buildings?.list.map((b) => b.id) ?? []
    window.__arenaBuildingSpec = (id) => this.buildings?.find(id)?.spec ?? null
```

- [ ] **Step 3: Run the test**

Run: `bin/rails test test/system/collapse_test.rb`
Expected: both pass. If "the server never reported a collapse" times out, check the browser
console output the harness prints — a boot exception is the usual cause.

- [ ] **Step 4: Commit**

```bash
git add test/system/collapse_test.rb app/javascript/game/engine.js
git commit -m "Prove a house comes down the whole way round"
```

---

### Task 9: Documentation

**Files:**
- Modify: `CLAUDE.md`
- Modify: `docs/superpowers/specs/2026-09-13-persistent-world-design.md`

- [ ] **Step 1: Replace CLAUDE.md's "Multiplayer — scaffolded, not wired up" section**

It currently says nothing imports `game/net/*`. After this work, `connection.js` is imported
and `snapshot.js` / `remote_vehicle.js` still are not. Say exactly that, and add:

- Destruction is authoritative in **one process**. `ArenaChannel::AUTHORITY` is claimed per
  match with a conditional UPDATE; a process that loses refuses `damage` and sends
  `error: "not_authoritative"`, so destruction degrades to nothing rather than diverging.
- Damage travels only over ActionCable, geometry only over HTTP. Never mix them.
- `breaks` is broadcast **without** a `player_id` so the sender receives it; every other
  broadcast is stamped.
- The monotone invariant, and that it is what lets the client predict breaks and never revert.

- [ ] **Step 2: Update the spec's status line**

Change `Status: approved, not yet implemented` to note which sections are built: §1–5, §9 and
§11 are in; §3 terrain, §6 chunk delivery, §7 instancing tiers and §8 promotion are not.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md docs/superpowers/specs/2026-09-13-persistent-world-design.md
git commit -m "Write down who is allowed to break what"
```

---

## Self-Review

**Spec coverage (§10):**
- `damage {seq, hits}` → Task 5 ✓ · `request_state` → Task 5 ✓ (per-object ids rather than
  per-chunk `{cx, cz}`, since chunk streaming does not exist yet — noted as a deliberate
  narrowing)
- `breaks {broken, collapses}` → Task 5 ✓ · `state` → Task 5 ✓ · `error` → Task 5 ✓
- Partial HP never broadcast → Task 5 ✓ (only `destroyed` and `collapsed_from` ship)
- Monotone invariant → Task 7 Step 2 ✓
- `Registry` + per-match `Monitor` + ~1s flush + flush on last unsubscribe → Task 4 ✓
- `transaction(isolation: :immediate)` → Task 3 ✓
- Authority claim, refusal, stamped on every message → Task 5 ✓
- Caps honest about not being security → Task 3 ✓
- `piece_count` bounds check → Tasks 1 and 2 ✓
- Rehydrate on first subscribe → Task 4 ✓

**Not covered, deliberately:** the `PREDICTED` / `DENY` reconciliation window and the 200ms
un-break animation. Nothing in this plan can deny a break — the server's rule is "any reported
damage that would break a piece breaks it", so a self-predicted break is always confirmed.
That machinery only earns its place when the server starts rejecting hits, which it does not
yet. Left out rather than built unused.

**Type consistency checked:** `apply_batch` returns String keys throughout
(`"broken"`, `"collapses"`); `state_for` returns String keys; `ObjectState#apply` takes an
Integer index and returns an Array; `PieceSet` raises on out-of-range while `ObjectState`
swallows it, which is the intended split — the bitset is a programming error, the wire is not.
