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
// A WALL's normal is level, so y says nothing there. Both generators build a wall from a
// footprint edge with u along the ring and v up, and every ring they lay down runs
// (x0,z0) -> (x1,z0) -> (x1,z1) -> (x0,z1) -- so u x v points INTO the building. Verified by
// a point-in-ring test over every wall of hills, targets and street: 152 of 152 inward, none
// out. Hence the constant -1 rather than a test of anything.
export function outward(surface) {
  if (surface.kind === "roof") return surface.n[1] < 0 ? -1 : 1
  return -1
}

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
  if (surface.kind !== "wall") return []

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
