# Debris made of the building

A second pass at what a collapsed building leaves behind. The first pass got the
machinery right and the picture wrong: the wreckage is shared, persistent, clearable
and addressed by piece index exactly as a wall is, but what it draws is a uniform dark
mound of slate-coloured lumps, four and a half metres tall at the middle and impassable
on purpose. Nothing in it says brick, timber or tile, and a truck that knocked the house
down cannot get through what it left.

The requirements this pass answers, in the words they were given:

1. When a building collapses its pieces fall under physics.
2. As pieces touch the ground a pile of debris grows, and it looks like it contains the
   pieces the building was made from.
3. The pile is many segments a rocket destroys individually; the monster truck clears
   through it easily, keeping its momentum.
4. Piles are shared in multiplayer; individual pieces of rubbish may be local.
5. When a segment is cleared, a couple of pieces of rubbish remain for a couple of
   seconds, then fade out and lower into the ground.

## What stays

Almost all of the previous design survives, and it is worth being explicit about which
parts, because each one was hard-won:

- **A heap is reserved piece indices on the building that produced it.** One `Surface`
  of `kind: :rubble`, appended last, `storey: -1`. Clearing goes through `damage` and
  `breaks`, persistence is a bit in `broken_pieces`, rejoining is `request_state`. No
  new message, table or column. Requirement 4 is met by this and stays met.
- **Heaps arrive as the slabs carrying them land**, revealed outward from the middle in
  the order `Building::Rubble.pile_indices` and `pileOrder` share with the server.
  Requirement 2's "grows as pieces touch the ground" is this mechanism; what changes
  is what a heap looks like when it appears.
- **Slabs fall as dynamic bodies** and shatter into shards on landing. Requirement 1.
- `DORMANT → INTACT → BROKEN`, the three defences against a collapse sweeping its own
  rubble, the two-number falling budget, the per-cell reporting rule. Untouched.
- The breakthrough refund the previous session added (`Vehicle#punchThrough`): a car
  that breaks a fixed piece is given back the speed the piece was not worth, instead
  of paying the solver's price for an immovable wall. That is the mechanism by which
  the truck keeps its momentum through a heap, and it is kept as it is.

## What changes

### A heap is drawn from the building's own materials

A heap keeps ONE piece index and ONE collider. It is drawn as a **base lump plus a
cluster of fragments**:

- The base lump is the existing seeded, normalised lump (`lumpGeometry`), in the
  `rubble` material's colour, which becomes a dusty mortar grey rather than slate. It is
  the body of the heap: it is what covers the ground, what the collider is sized from,
  and what stops the cluster reading as chunks floating over bare earth.
- The fragments are chunks of brick, timber, concrete, tile, plaster and glass sitting in
  and on the lump, each drawn from a per-material fragment pool (`brick#rubble`,
  `timber#rubble`, …). The suffix picks a shape and never a material, exactly as
  `rubble#3` does today.

**Which materials, and how much of each, is the building's own business, and Ruby
decides it.** `Rubble.build` is already handed the walls, floors and roof; it now also
totals their volume *per material* and ships the shares as `mix` on the rubble surface.
The worked-example house comes out brick 38%, timber 26%, concrete 13%, roof tile 13%,
glass 6%, plaster 5%, steel a trace. A bungalow with a flat concrete roof reads
differently from a gabled brick house, and nobody chose a number.

**How a material breaks into chunks is a property of the material.** `Game::Material`
gains a `chunk` block — a mean size on each axis, how much it varies, how irregular the
shape is — so a timber fragment is a long thin plank, a roof tile a flat plate, a brick
a stubby block. It ships with the rest of the material table, so the client holds no
constants of its own.

**Fragment placement is seeded, and never `Math.random`.** For fragment `k` of a heap,
position within the heap's ellipse, height on the dome, yaw, lean and per-axis size all
come from `noise(surface, row, col, salt + k)`. Two clients therefore draw identical
heaps without a byte on the wire, and a test can compare them.

**The count is fixed per heap** (`rules.collapse.rubble.fragments`), because the
instanced pools are allocated once at boot and cannot grow. `Building.countMaterials`
counts fragments by running the same deterministic material draw the builder runs, so
the pool for brick fragments is exactly as large as the world's heaps will ever need.
A rim heap gets the same number of fragments as a centre heap, smaller; scattered small
chunks at the edge of a pile are what the edge of a pile looks like.

### The pile is lower, and the truck goes through it

`Rubble::SHARE` comes down from 0.6 to 0.2 and the dome's `falloff` from 1.8 to 1.2.
Measured on the worked example: mean depth 0.59 m, peak 1.68 m, rim 0.13 m, against
1.76 / 6.0 / 0.53 before. A heap's health, computed from that depth on both sides, comes
to about 15.

What that buys, with numbers from the rules as they stand:

- The truck's blade multiplies damage by five. At 6 m/s a blade hit is 28 after the
  rubble multiplier, which breaks a heap outright; at 12 m/s it is 112 and the spread
  breaks the neighbours too. The truck clears heaps at any speed it can reach them at.
- The truck's wheels are raycasts, not colliders. A rim heap 13 cm tall is simply driven
  over; the blade meets the heaps that are tall enough to matter and breaks them. So the
  truck rides up the shallow rim and ploughs the middle, which is the behaviour asked for.
- `punchThrough` then gives back what those heaps were not worth: three heaps are 46
  health, 23 m/s of worth, 3.5 m/s of cost at the truck's `cost` of 0.15.
- A rocket is worth at least 90 at its centre and falls off linearly to 2.5 m, so it
  breaks the heaps within about two metres of where it lands and leaves the rest: a
  patch, not the pile. The buggy's own body barely dents one; it has a rocket for that.

The heap collider becomes a **level box** — the base lump's own extents, spun about world
up but no longer leaned — because a car driving over forty tilted boxes is a car driving
over forty invisible ramps. The lean moves to the fragments, where it belongs.

### A heap rises out of the ground rather than popping into it

A revealed heap grows in over `rules.collapse.rubble.rise` seconds: the lump's height
and the fragments' size are scaled by an eased factor and their positions follow. The
collider is enabled at once; only the drawing eases. With the slabs landing over about a
second and a half and the heaps revealed in proportion, the pile visibly builds up out of
the ground under the falling walls, which is requirement 2's "slowly grow".

### Clearing a heap leaves its pieces lying there for a moment

When a heap breaks and the break is not silent:

- Two of its fragments are thrown as shards through `Debris`, in their own materials, so
  the impact reads in the colours of what was hit.
- `rules.collapse.rubble.remnants.keep` of its fragments (three) are handed to a new
  `Remnants` pool as plain meshes, each with its own transparent material. A remnant
  first **settles** to the ground over a third of a second, because the lump it was
  lying on has gone; **lingers** for two seconds; then over a second and a half **fades
  to nothing while sinking by its own height**. Then it returns to the pool.

Remnants have no colliders and never go on the wire. They are the "individual pieces of
rubbish" of requirement 4, and requirement 5 in full.

### Draw calls

The base lumps drop from sixteen shapes to twelve, the minimum the existing test allows,
and the fragment pools add one per material that appears in any building's mix — seven
on the targets house. Every one of these pools is switched off while it draws nothing,
so an intact street costs what it costs today; a fallen house costs about nineteen draws
more than an intact one, against thirty-four for the whole intact world.

## Data flow

```
Ruby   Rubble.build(recipe, built)  →  Surface(kind: :rubble, mix: {brick: 0.38, …})
       Material#chunk                →  materials[name].chunk
       Spec.default_rules            →  rules.collapse.rubble.{fragments, rise, remnants, …}

JS     Building.countMaterials       counts base lumps AND fragments per pool
       Buildings                     registers `${material}#rubble` shapes before allocate
       Building#build                adds lump + fragments hidden; collider from the level box
       Building#reveal               shows all, starts the rise
       Building#update(dt)           advances rising heaps
       Building#breakCell            hides all; shards + remnants when not silent
       Remnants#update(dt)           settle → linger → fade+sink → pool
```

Nothing new crosses the wire. `mix` and `chunk` ride the spec that already ships with
the page.

## Testing

**Ruby, fast:**

- `rubble_test.rb`: `mix` sums to one, excludes void and rubble, names brick as the
  largest share of the worked example, and ships in `to_spec`; the worked example's mean
  depth is under a metre, so the pile is something a truck ploughs.
- `materials_test.rb`: every material but void ships a `chunk` with positive sizes.
- `spec_test.rb`: the rubble rules carry `fragments`, `rise` and `remnants`, with the
  bounds that make them meaningful; the existing neighbour-reach invariant still holds.

**System, browser:**

- A revealed heap's fragments are drawn from more than one of the building's materials,
  and include its dominant one. Via a new hook, `__arenaHeapFragments(piece, id)`.
- Two players see identical fragments, not merely identical heaps. The existing
  agreement test compares heap matrices; it grows to compare fragment materials too.
- Clearing a heap leaves remnants, and they are gone after linger plus fade. Via
  `__arenaRemnants()`.
- The truck drives through a fallen house's pile and comes out the other side still
  moving, having cleared heaps on the way. Calibrated in the browser before it is
  written, with the margin the CLAUDE.md testing notes ask for.

## Deliberately not in scope

- Heaps still do not move, stack or shove. A remnant is a picture.
- Falling slabs still shatter on landing rather than persisting as bodies. The pile is
  what persists.
- No terrain: the ground is `y = 0` everywhere, as it is for the shards.
