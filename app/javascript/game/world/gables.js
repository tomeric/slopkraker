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
// new shape pool per material -- from there to the higher, turned toward the apex. A column
// the line peaks inside -- which only happens when the gable has an odd number of them --
// gets two half-width wedges instead.
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

    if (tL < 0.5 && tR > 0.5) {
      // The apex column: the line rises to the peak inside it and falls again.
      const low = Math.min(yL, yR)
      if (low > yK) box = { x0, width: cellW, y0: yK, height: low - yK }
      const base = Math.max(yK, low)
      const half = cellW / 2
      if (surface.h > base) {
        wedges.push({ x0, width: half, y0: base, height: surface.h - base, high: 1 })
        wedges.push({ x0: x0 + half, width: half, y0: base, height: surface.h - base, high: -1 })
      }
    } else {
      const low = Math.min(yL, yR)
      const high = Math.max(yL, yR)
      if (low > yK) box = { x0, width: cellW, y0: yK, height: low - yK }
      const base = Math.max(yK, low)
      if (high > base) wedges.push({ x0, width: cellW, y0: base, height: high - base, high: yR > yL ? 1 : -1 })
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

// A unit right triangular prism: x from 0 to 1, y from 0 to 1, z from -0.5 to 0.5; the
// vertical face at x = 1, the slope from (0, 0) to (1, 1), so scaling by (width, height,
// thickness) and placing at a column's left edge fills a tooth that is higher on the right.
// The other way round is the same shape turned half a turn about v.
//
// Not indexed, and deliberately: computeVertexNormals on separate vertices gives every face
// its own flat normal, which is what a cut stone reads as. Each face is wound
// counter-clockwise seen from outside -- the comments say which way each one looks, and a
// face wound the other way renders black and vanishes at a grazing angle.
export function wedgeGeometry() {
  const a = [ 0, 0, -0.5 ], b = [ 1, 0, -0.5 ], c = [ 1, 1, -0.5 ]
  const d = [ 0, 0, 0.5 ], e = [ 1, 0, 0.5 ], f = [ 1, 1, 0.5 ]
  const positions = [
    // back triangle (z = -0.5), facing -z
    ...a, ...c, ...b,
    // front triangle (z = +0.5), facing +z
    ...d, ...e, ...f,
    // bottom (y = 0), facing -y
    ...a, ...b, ...e, ...a, ...e, ...d,
    // vertical face (x = 1), facing +x
    ...b, ...c, ...f, ...b, ...f, ...e,
    // slope, facing (-1, 1, 0)
    ...a, ...d, ...f, ...a, ...f, ...c
  ]
  const geometry = new THREE.BufferGeometry()
  geometry.setAttribute("position", new THREE.Float32BufferAttribute(positions, 3))
  // Metres-along-the-face uv is what the metres chunk computes; a plain uv keeps the
  // fallback path sane for a material with no look.
  const uv = []
  for (let i = 0; i < positions.length; i += 3) uv.push(positions[i], positions[i + 1])
  geometry.setAttribute("uv", new THREE.Float32BufferAttribute(uv, 2))
  geometry.computeVertexNormals()
  return geometry
}
