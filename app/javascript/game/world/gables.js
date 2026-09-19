import * as THREE from "three"
import { materialAt } from "game/world/surface"

// The gable ends meet the roof.
//
// A gable is a stair of whole cells, clipped by Roof.clip against the roof line, and the
// stair IS the piece numbering -- Ruby and JavaScript count the same grid, and nothing here
// may change that. What a player sees, though, is a wall that stops short of the roof in
// teeth. So the client fills the tooth above every column's topmost standing cell with two
// extra instances in the gable's own material and tint: a BOX up to the lower of the roof
// line's two heights across the column, and a WEDGE -- a unit right triangular prism, one
// new shape pool per material -- from there to the higher, turned toward the apex. The apex
// column of a gable with an odd number of columns is kept whole by Roof.clip -- its centre
// sits exactly on the ridge, so the line clips nothing in that column -- and needs no cap.
//
// Caps are drawing. They are placed at boot, counted into the pools like a heap's chunks,
// hidden when the cell under them breaks and shown when it is restored. They have no
// collider: the tooth was never something a car could hit.

export const WEDGE_SUFFIX = "#wedge"

export function wedgePool(name) {
  return `${name}${WEDGE_SUFFIX}`
}

export function isWedgePool(pool) {
  return pool.endsWith(WEDGE_SUFFIX)
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

    // The same two-height path for every column, apex included. A gable with an odd number
    // of columns does have one whose centre fraction is exactly 0.5 -- the ridge -- but that
    // is exactly the column where the stair reaches the ridge with nothing clipped: yK is
    // already the full height, so `low > yK` and `high > base` both fail and this produces
    // an empty box and no wedges, which is the right answer rather than a case to special-case.
    const low = Math.min(yL, yR)
    const high = Math.max(yL, yR)
    if (low > yK) box = { x0, width: cellW, y0: yK, height: low - yK }
    const base = Math.max(yK, low)
    if (high > base) wedges.push({ x0, width: cellW, y0: base, height: high - base, high: yR > yL ? 1 : -1 })

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
