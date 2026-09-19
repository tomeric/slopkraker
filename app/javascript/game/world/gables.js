import * as THREE from "three"
import { materialAt } from "game/world/surface"

// A clipped surface meets the roof.
//
// A gable end is a stair of whole cells, clipped by Roof.clip against the roof line, and the
// stair IS the piece numbering -- Ruby and JavaScript count the same grid, and nothing here
// may change that. What a player sees, though, is a wall that stops short of the roof in
// teeth. So the client fills the tooth above every column's topmost standing cell with two
// extra instances in the surface's own material and tint: a BOX up to the lower of the roof
// line's two heights across the column, and a WEDGE -- a unit right triangular prism, one
// new shape pool per material -- from there to the higher, turned toward the apex.
//
// A HIPPED ROOF'S PLANES ARE CAPPED THE SAME WAY, which is why nothing here says `gable`
// except the names. A pyramid plane is a rectangle carrying an isoceles triangle whose apex
// is at (w / 2, h) in the plane's own frame -- exactly the line below -- so the arithmetic
// generalises without a special case. What does NOT generalise is telling the two apart:
// a pyramid plane is `kind: "roof"`, indistinguishable from the unclipped plane of an
// ordinary gable roof, so the generator ships `caps` and this module never guesses.
//
// THE APEX COLUMN IS A TENT AND NOT A SLOPE. Roof.clip keeps only what is wholly under the
// roof across the WHOLE of a column, so the column the ridge falls inside -- an odd column
// count, always -- is clipped to the lower of its two ends like any other: on a 9-column
// gable both its ends are at 8/9 of the height while its middle is the ridge itself. One
// wedge would fill it to 8/9 and stop, and the gable would lose its peak to a flat notch.
// So that column gets TWO wedges of half its width, one rising to the apex and one falling
// from it. While the clip judged a column by its MIDDLE this never came up: the apex column
// was kept whole, needed no cap at all, and stood a ninth of the height proud of its roof.
//
// Caps are drawing. They are placed at boot, counted into the pools like a heap's chunks,
// hidden when the cell under them breaks and shown when it is restored. They have no
// collider -- for a gable's tooth because it was never something a car could hit, and for a
// hipped plane's because a cap HAS NO PIECE INDEX. A collider on one would be solid and
// unbreakable, hidden by a cell that on an eaves column is not even its own; a car would
// land on a ledge nothing can address. The cost is real and measured: on Sint-Marcellinus's
// spire the caps draw about half of each plane, some 17 m2, with nothing behind it -- but
// that is 19 to 27 m up a church tower, and the 0.4 m eaves overhang already makes the same
// bargain along every roof in the game.

export const WEDGE_SUFFIX = "#wedge"

export function wedgePool(name) {
  return `${name}${WEDGE_SUFFIX}`
}

export function isWedgePool(pool) {
  return pool.endsWith(WEDGE_SUFFIX)
}

// Whether this surface leaves a step for caps to fill. Ruby's word, never inferred: `kind`
// cannot answer it, because a pyramid's clipped planes and a gable roof's plain ones are
// both `roof`. Absent means no, which is every wall, floor, deck and unclipped plane --
// the same shape of default as `outward`, and shipped only where it is true.
export function capped(surface) {
  return surface.caps === true
}

// The roof line Roof.clip judges by: a triangle over the gable's width, `1 - |2t - 1|` of
// its height at fraction `t` across.
function lineAt(t, height) {
  return height * (1 - Math.abs(2 * t - 1))
}

// Per column: the topmost standing row (or -1), the box and the wedges that fill the tooth
// above it. `anchorCol` is the column whose top cell the caps go with: the column itself,
// or, for a column with no standing cell at all (the eaves corners), the nearest column
// toward the apex that has one -- so nothing hangs at the eaves after a collapse.
export function gableCaps(surface) {
  const cellW = surface.w / surface.cols
  const cellH = surface.h / surface.rows
  const tops = []
  for (let col = 0; col < surface.cols; col += 1) {
    let top = -1
    for (let row = surface.rows - 1; row >= 0; row -= 1) {
      if (materialAt(surface, row, col) !== "void") { top = row; break }
    }
    tops.push(top)
  }

  const caps = []
  for (let col = 0; col < surface.cols; col += 1) {
    const yK = (tops[col] + 1) * cellH
    const x0 = col * cellW
    const tL = col / surface.cols
    const tR = (col + 1) / surface.cols
    const yL = lineAt(tL, surface.h)
    const yR = lineAt(tR, surface.h)
    const wedges = []
    let box = null

    // Whether the ridge falls strictly INSIDE this column rather than on one of its seams.
    // `1 - |2t - 1|` peaks at t = 0.5, so a column that straddles it carries a tent: two
    // slopes, not one. It can only happen with an odd column count, and then the column is
    // centred on the ridge -- yL === yR, and the peak is over the column's own middle.
    const tent = tL < 0.5 && tR > 0.5

    const low = Math.min(yL, yR)
    const high = Math.max(yL, yR)
    // One box under the whole column either way: the box fills to the LOWER end, and under
    // a tent both ends are the same height, so there is one level to fill to.
    if (low > yK) box = { x0, width: cellW, y0: yK, height: low - yK }
    const base = Math.max(yK, low)
    if (tent) {
      // Two half-width wedges meeting over the middle at the full height: the left one
      // rising to the peak, the right one falling from it. `high` on a tent equals `low`,
      // so the single-wedge path below would draw nothing here and flatten the ridge.
      if (surface.h > base) {
        const half = cellW / 2
        wedges.push({ x0, width: half, y0: base, height: surface.h - base, high: 1 })
        wedges.push({ x0: x0 + half, width: half, y0: base, height: surface.h - base, high: -1 })
      }
    } else if (high > base) {
      wedges.push({ x0, width: cellW, y0: base, height: high - base, high: yR > yL ? 1 : -1 })
    }

    let anchorCol = col
    if (tops[col] < 0) {
      const step = tL < 0.5 ? 1 : -1
      for (let c = col + step; c >= 0 && c < surface.cols; c += step) {
        if (tops[c] >= 0) { anchorCol = c; break }
      }
    }
    caps.push({ col, anchorRow: tops[anchorCol], anchorCol, box, wedges })
  }
  return caps
}

// A unit right triangular prism, CENTRED like the unit cube every standing piece is built
// from: x from -0.5 to 0.5, y from -0.5 to 0.5, z from -0.5 to 0.5; the vertical face at
// x = +0.5, the slope from (-0.5, -0.5) to (+0.5, +0.5). Scaling by (width, height,
// thickness) and placing by its CENTRE -- never a corner -- fills a tooth that is higher on
// the right. The other way round is the same shape turned half a turn about v, which keeps
// the centre fixed, so both handednesses place at the same point. Centred rather than
// corner-anchored because the metres shader chunk assumes it: `(position + 0.5) *
// metresScale` only spans the piece's own [0, size] when `position` starts out [-0.5, 0.5],
// exactly as it does for the box cap and for every wall cell's own unit cube.
//
// Not indexed, and deliberately: computeVertexNormals on separate vertices gives every face
// its own flat normal, which is what a cut stone reads as. Each face is wound
// counter-clockwise seen from outside -- the comments say which way each one looks, and a
// face wound the other way renders black and vanishes at a grazing angle.
export function wedgeGeometry() {
  const a = [ -0.5, -0.5, -0.5 ], b = [ 0.5, -0.5, -0.5 ], c = [ 0.5, 0.5, -0.5 ]
  const d = [ -0.5, -0.5, 0.5 ], e = [ 0.5, -0.5, 0.5 ], f = [ 0.5, 0.5, 0.5 ]
  const positions = [
    // back triangle (z = -0.5), facing -z
    ...a, ...c, ...b,
    // front triangle (z = +0.5), facing +z
    ...d, ...e, ...f,
    // bottom (y = -0.5), facing -y
    ...a, ...b, ...e, ...a, ...e, ...d,
    // vertical face (x = +0.5), facing +x
    ...b, ...c, ...f, ...b, ...f, ...e,
    // slope, facing (-1, 1, 0)
    ...a, ...d, ...f, ...a, ...f, ...c
  ]
  const geometry = new THREE.BufferGeometry()
  geometry.setAttribute("position", new THREE.Float32BufferAttribute(positions, 3))
  // Metres-along-the-face uv is what the metres chunk computes; a plain uv keeps the
  // fallback path sane for a material with no look -- shifted back to [0, 1] since the
  // position attribute itself is now centred on [-0.5, 0.5].
  const uv = []
  for (let i = 0; i < positions.length; i += 3) uv.push(positions[i] + 0.5, positions[i + 1] + 0.5)
  geometry.setAttribute("uv", new THREE.Float32BufferAttribute(uv, 2))
  geometry.computeVertexNormals()
  return geometry
}
