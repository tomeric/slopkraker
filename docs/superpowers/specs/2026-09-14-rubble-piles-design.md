# Rubble piles

A collapsed building leaves little heaps of garbage on its footprint. They are solid, they
have to be cleared, they are in the same place for everybody, and they are still there
tomorrow.

## Why this is not a new kind of object

The obvious shape — a rubble row created when the house falls — cannot work, and the reason
is worth stating first because it rules out most of the design space.

`world_objects` belong to a **world**. `object_damages` belong to a **(match, object)** pair.
That split is what lets one seeded world be played by any number of matches, each wrecking
it independently. A rubble row created by a collapse in one match would exist in every
match, including the ones where that house is still standing. Putting `match_id` on
`world_objects` would dissolve the split the whole schema rests on.

So rubble is not a new object. **Rubble is reserved piece indices on the building that
produced it.**

Every building already reserves index space it may never use: a doorway is a real index
holding `void`, a gable's clipped corners are real indices holding `void`. The rule that
piece index space is never culled exists precisely so that indices can be reserved for
things that are not there. Rubble extends it by one step — indices reserved for things that
are not there *yet*.

Everything else follows from that one decision, and almost all of it is already built:

| Requirement | How it is met |
|---|---|
| Same positions for everyone | Derived from `(recipe.seed, collapsed_from)`, like the 1454 pieces already derived from a 300-byte recipe |
| Piles can be cleared | `damage` → absorb → `breaks`, addressed by `[object_id, piece_index]` — **no protocol change** |
| Clearing persists | A set bit in `broken_pieces` — **no schema change** |
| A joining client catches up | `request_state` already sends `collapsed_from` and the bitset |

No new message, no new table, no new column.

## The pile grid

A rubble surface is a `Game::Building::Surface` like any other, with `kind: :rubble`, lying
flat on the ground over the building's footprint. Cells are coarse — `RUBBLE_CELL = 2.0`
metres against the building's own 1.0 — and each cell holds either one pile or `void`.

Using a Surface rather than a new concept is most of the value of this design. `at`,
`material_at`, `cell_area`, `piece_index`, `covers?`, the client's expansion, the instanced
mesh pools and the collider arrays all work with no change whatever.

**Extent.** The footprint's bounding box, divided into whole 2m cells, so a 12×15m house
gives a 6×8 grid of 48 cells.

**Which cells hold a pile.** A cell holds a pile when its centre is inside the footprint
polygon and a seeded draw passes. The draw is `Openings`-style: deterministic in
`recipe.seed` and the cell's own row and column, so every client and the server agree
without exchanging anything. Tuned to leave roughly 40 piles on the targets house.

**Partial collapses.** A building that came down from its top storey leaves less than one
gutted to the ground. The pile count scales with how much fell:

```
filled = round(total_piles * (storey_count - collapsed_from) / storey_count)
```

Indices are reserved for the maximum — a full collapse — and a partial one fills a prefix.
Reserving the maximum is what keeps `piece_count` a property of the recipe alone, which it
must be, because it is stored on the row and bounds-checks every reported index.

**Generation order.** The rubble surface is appended **last**, after `Walls + Interior +
Roof`. This is not cosmetic: `SurfaceSet` hands out offsets by walking surfaces in sequence,
so anything inserted earlier renumbers every piece after it, and damage recorded against a
wall would come back applied to the roof. Last is the only position that leaves all existing
indices untouched.

## The third state

A piece today is `INTACT → BROKEN`, monotone, never backwards. That invariant is what makes
every server message idempotent, lets a client predict a break it never has to undo, and
makes a rollback after a restart invisible.

A pile has to *appear*, which looks like a violation and is not. It runs:

```
DORMANT → INTACT → BROKEN
```

Still strictly monotone — it enters one state earlier and never moves backwards — and the
bitset still records only the final transition. `DORMANT → INTACT` is not stored at all: it
is implied by `collapsed_from` being set, which is itself monotone and already persisted.

**Server rule**, one clause in `ObjectState#apply`: a rubble index is damageable only when
`collapsed_from` is non-nil and the index falls within the prefix that collapse filled.
Damage to a dormant pile is dropped the same way an out-of-range index is dropped — it
arrived over a socket, and a channel is not the place to crash on a malformed message.

**Client rule**: rubble pieces are built at boot with their colliders disabled and their
instances at zero scale, exactly as a broken piece is. A collapse reveals the filled prefix.
Revealing is idempotent, so a `breaks` message replayed or a `state` message arriving after
a live collapse costs nothing.

**Revealing moves `DORMANT → INTACT` only, and never `BROKEN → INTACT`.** That single clause
is what makes the order of `applyState`'s two halves irrelevant. It currently applies the
broken bitset first and the collapse second, so without it, rejoining a match where piles had
been cleared would reveal them again — every cleared pile back on the street, on every page
load, and monotonicity broken in the one direction it may not move.

## The collapse rule must not see rubble

`Damage::Collapse` sweeps **every cell of every surface at or above the failed storey**
(`fell_from`, via `each_cell(from: storey)`). A rubble surface left visible to it would be
destroyed by the very collapse that creates it, and would also be weighed as mass and as
structural area on the way down.

The primary defence is that the rubble surface is given **`storey: -1`**. Every sweep in
`Collapse` is bounded from below by a real storey — `fell_from` asks `each_cell(from: storey)`
with `storey >= 0`, `mass_above` asks `from: storey + 1`, `for_storey` matches exactly, and
`lowest_failing` only ever iterates `(0...ceiling)`. A surface below every storey is therefore
already outside all four.

`Collapse` **also** skips `:rubble` by kind, and the material carries `structural_weight: 0.0`.
Three independent defences for one rule, deliberately: this is the single place in the design
where a mistake is both silent and permanent — the collapse would quietly destroy the rubble it
was in the act of creating, and no message or test downstream would look wrong.

## What a pile is made of

A new frozen entry in `Game::Materials`:

```ruby
rubble: Material.new(
  name: :rubble, colour: "#4f4a3e",   # drab, refuse-coloured, not masonry
  health_per_m2: 2.5, density: 400.0, # light: a heap of bags, not a heap of bricks
  structural_weight: 0.0,             # holds nothing up, ever
  multipliers: { impact: 1.3, blast: 1.5 },
  fracture: { method: "voronoi", mode: "2.5D", fragments: 8 }
)
```

A pile is one 2m cell, 0.5m high, so `health_for` gives
`2.5 * 4.0 * sqrt(0.5 / 0.25)` ≈ **14** — one solid hit at speed, or two casual ones.

`structural_weight: 0.0` is the third of the defences above: it makes a pile non-structural
by construction, so `structural_area` returns zero for it whatever else changes.

## How a pile is drawn

One squat box per pile, expanded client-side with a transform seeded from the cell — a yaw,
a size variation, and a jitter within the cell so the piles do not read as the grid they are
on. The server never computes a pile's transform and does not need to; positions agree
because the seed does.

Appearance is the part most likely to need a second pass. "Little piles of garbage" is a
look, and one box may not carry it. The grid, the indices and the state machine are
independent of how a pile is drawn, so the look can be revisited without touching any of it.

## Tuning

Everything lands in `Game::Spec.default_rules` under `collapse`, beside `fall`:

```ruby
rubble: {
  cell: 2.0,        # metres; the pile grid's coarseness
  density: 0.85,    # share of in-footprint cells that hold a pile
  jitter: 0.3,      # how far a pile may sit from its cell centre, as a share of the cell
  height: 0.5       # knee-high
}
```

## What changes

| File | Change |
|---|---|
| `game/building/rubble.rb` | New. Recipe → one rubble `Surface`, and the filled-prefix rule. |
| `game/building/generator.rb` | Appends the rubble surface last. |
| `game/building/surface.rb` | `:rubble` joins `KINDS`. |
| `game/damage/collapse.rb` | Skips `:rubble` in `each_cell`, `structural_area`, `mass_above`. |
| `game/damage/object_state.rb` | Rubble is damageable only once `collapsed_from` is set. |
| `game/materials.rb` | The `rubble` entry. |
| `game/spec.rb` | The `rubble` tuning block. |
| `world/building.js` | `DORMANT` state; `reveal()`; rubble cells expanded with their own transform. |
| `world/buildings.js` | A collapse reveals rubble as well as breaking pieces. |
| `db/seeds.rb`, fixtures | `piece_count` grows by the reserved rubble. |

## Testing

**Ruby, fast, no fixtures** — the bulk of it, because this is mostly rules:

- `rubble_test.rb` — a recipe yields a deterministic pile set; the same seed twice gives the
  same piles; a different seed gives different ones; the filled prefix scales with how many
  storeys fell.
- `generator_test.rb` — the worked example grows to pin the rubble offset and the new piece
  count. It already pins order, offsets and count; this keeps it honest.
- `collapse_test.rb` (model) — **a collapse does not destroy its own rubble**, and a rubble
  surface contributes neither mass nor structural area. This is the silent-and-permanent
  failure, so it gets an explicit test rather than being implied by a system test.
- `object_state_test.rb` — damage to a dormant pile is dropped; the same damage lands once
  `collapsed_from` is set; clearing a pile sets its bit.

**System, browser** — only what genuinely needs one:

- A collapse leaves piles standing on the footprint, and they are solid.
- Driving into a pile clears it, and it stays cleared across a reload (the existing
  persistence path, which is where a regression would actually hurt).
- Two Capybara sessions see piles in the **same positions** — the requirement that started
  this, and the only one a single session cannot prove.

## Deliberately not in scope

- **Piles are not pushed around.** They break; they do not shove. Shoving is client physics,
  which would put their positions back where this design started.
- **Piles do not damage the car**, consistent with falling masonry not damaging it.
- **Piles do not stack, settle or interact with each other.** They are static colliders, like
  every standing piece.
- **No rubble from anything but a collapse.** Knocking one panel out of a wall leaves shards,
  as it does now.
