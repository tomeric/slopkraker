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

// Which way is OUT of a surface, as a sign to push a fitting along its normal by. A surface
// carries `n = u x v` and nothing that says which of its two faces the weather is on, so
// this is the one thing a fitting cannot read straight off the spec.
//
// A ROOF plane's outward face is the one the sky sees, so the sign of the normal's y settles
// it. It genuinely differs between the two planes of one roof: measured on the targets house,
// u is (0, 0, 1) for both, so u x v comes out (-0.53, 0.848, 0) on the plane that rises east
// and (-0.53, -0.848, 0) on the one that rises west -- up out of the first and down into the
// second. A gutter pushed along +n on the second hangs in the attic. Chosen over inferring
// the side from v's y, which is positive on both planes and says only that they rise.
//
// A WALL's normal is level, so y says nothing there. A ring hand-laid by a generator
// always runs (x0,z0) -> (x1,z0) -> (x1,z1) -> (x0,z1), and for that winding u x v points
// INTO the building -- true for every wall of hills, targets and street (152 of 152, by a
// point-in-ring test), which is why -1 used to be returned unconditionally here. It is
// not a safe assumption for an IMPORTED ring: PostGIS makes no promise about winding, and
// 58 of geleen's 93 box rings run the other way, where u x v already points out. Ruby
// knows which way its own ring turned (Game::Building::Walls.outward) and ships the
// answer as `out` only when it differs from the default -- absent means -1, exactly as an
// absent `bay` means 0.
export function outward(surface) {
  if (surface.kind === "roof") return surface.n[1] < 0 ? -1 : 1
  return surface.out ?? -1
}

// A dakkapel's four surfaces and a chimney's four walls are surfaces of a building like any
// other, but neither should carry rainwater goods: a gutter belongs under the tiles of the
// main roof, not round a zinc box on the slope, and a downpipe against the house's own
// wall, not a stack 0.9 m square. Ruby decides this at generation time, never the client --
// a chimney's walls are ordinary brick like any other wall, so no rule keyed on material
// could tell the two apart -- and ships it as `surface.fittings`. Absent means yes, the
// same as every other flag omitted at its default, so both guards below check `=== false`
// rather than treating a merely falsy value as a no.

// How much of a roof plane's up-slope direction has to be vertical before the plane counts
// as PITCHED. A roof surface's v runs up the slope, so v.y is the sine of the pitch: about
// 0.49 on the worked terrace, and exactly zero on anything that is really a deck -- a flat
// box roof, a flat-roofed dwelling's section, a dakkapel's top, a gable row whose ridge sits
// at its eaves. 0.02 is a pitch of just over one degree, which no roof in any world has and
// no float error reaches.
export const PITCHED = 0.02

// One gutter box per column of a roof plane's bottom row, hung just below the eaves edge
// and just outside it, so it sits under the tiles' lip rather than in them.
//
// ONLY on a pitched plane. A deck has no eaves: water does not run off one edge of it, and
// a 12 cm bar laid along whichever edge the grid happened to call row 0 is a kerb round part
// of a bounding box rather than a gutter -- 507 of geleen's 1,529 gutter boxes were exactly
// that. Nothing here touches DOWNPIPES: those hang on walls, and a flat-roofed annexe still
// drains down its own wall like every other box, so its pipes stay.
export function gutters(surface) {
  if (surface.kind !== "roof" || surface.fittings === false) return []
  if (Math.abs(surface.v[1]) < PITCHED) return []

  const width = surface.w / surface.cols
  const out = []
  for (let col = 0; col < surface.cols; col += 1) {
    out.push({
      anchorRow: 0,
      anchorCol: col,
      // Centred on its column, half a section below the plane's lower edge, and half a
      // section proud of the plane's own OUTWARD face.
      u0: (col + 0.5) * width,
      v0: -GUTTER_SIDE / 2,
      n0: outward(surface) * (GUTTER_SIDE / 2 + surface.t / 2),
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
  if (surface.kind !== "wall" || surface.fittings === false) return []

  const col = surface.cols - 1
  return [ {
    anchorRow: 0,
    anchorCol: col,
    // Against the far end of the wall and proud of its outward face, running its whole height.
    u0: surface.w - GUTTER_SIDE / 2,
    v0: surface.h / 2,
    n0: outward(surface) * (GUTTER_SIDE / 2 + surface.t / 2),
    su: GUTTER_SIDE,
    sv: surface.h,
    sn: GUTTER_SIDE
  } ]
}

// Every fitting of a surface, whatever kind it is.
export function fittingsFor(surface) {
  return [ ...gutters(surface), ...downpipes(surface) ]
}
