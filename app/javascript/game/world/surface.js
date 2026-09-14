import * as THREE from "three"

// Turning a surface back into the cells it describes.
//
// This is the other half of Game::Building::Surface, and the only new piece of logic that
// has to agree across the two languages. It is deliberately trivial and TOTAL: every row
// and column produces a cell, always. Nothing here decides that a cell should be skipped,
// because piece indices are counted from the grid -- if either side culled, the two would
// have to cull identically forever, and the first divergence would renumber every piece
// after it.
//
// A doorway is not a missing cell. It is a cell whose material is `void`, which the caller
// then declines to give a body or a mesh. Same index, same arithmetic, nothing to get
// wrong.

// Reused for every cell of every surface: expanding a building allocates nothing.
const u = new THREE.Vector3()
const v = new THREE.Vector3()
const n = new THREE.Vector3()
const position = new THREE.Vector3()
const scale = new THREE.Vector3()
const matrix = new THREE.Matrix4()
// Walked backwards, because the last patch covering a cell wins -- a lintel laid over a
// window opening has to read as the lintel.
export function materialAt(surface, row, col) {
  for (let i = surface.patches.length - 1; i >= 0; i -= 1) {
    const [ col0, row0, col1, row1, material ] = surface.patches[i]
    if (row >= row0 && row <= row1 && col >= col0 && col <= col1) return material
  }
  return surface.mat
}

export function pieceIndex(surface, row, col) {
  return surface.off + row * surface.cols + col
}

export function cellSize(surface) {
  return { width: surface.w / surface.cols, height: surface.h / surface.rows }
}

// The cell's transform, composed T * R * S and never T * S * R. The order matters: three
// derives an instance's normals by dividing out the squared column lengths of its matrix,
// which is the correct inverse-transpose only while the matrix carries no shear. Scaling
// before rotating introduces exactly that shear, and the lighting goes subtly wrong in a
// way that is very hard to attribute later.
// Cells sit flush: exactly coplanar, exactly abutting, all the same size.
//
// They did not, for a while. Each was nudged out of plane, rolled a couple of degrees and
// given its own shade, to stop a wall reading as graph paper -- and the result read as a
// patchwork of separate boxes stacked against each other, which is worse. A wall is one
// object that happens to be destructible; the irregularity belongs in how it comes APART,
// which is what the block tiling is for, not in how it looks standing up.
export function cellMatrix(surface, row, col, target, origin) {
  const width = surface.w / surface.cols
  const height = surface.h / surface.rows

  u.fromArray(surface.u)
  v.fromArray(surface.v)
  n.fromArray(surface.n)

  // Cells are centred on the surface plane, so a wall's thickness straddles the line its
  // origin describes rather than hanging off one face of it.
  position
    .fromArray(surface.o)
    .addScaledVector(u, (col + 0.5) * width)
    .addScaledVector(v, (row + 0.5) * height)

  if (origin) position.add(origin)

  target.makeBasis(u, v, n)
  target.scale(scale.set(width, height, surface.t))
  target.setPosition(position)
  return target
}

// The transform of a RECTANGLE of cells, for a slab that falls as one body. Composed
// exactly as cellMatrix composes one cell -- same basis, same centring on the surface
// plane, same T * R * S order and for the same shear reason -- so a slab starts life
// occupying precisely the space its cells did, down to the thickness straddling the plane.
//
// Its local axes are the surface's: x along u (columns), y along v (rows), z along the
// normal. Callers rely on that to place things inside the slab, which is how a landing
// slab throws one cell's worth of shards per cell it covered rather than one enormous
// fragment per slab.
export function chunkMatrix(surface, row, col, rows, cols, target, origin) {
  const width = surface.w / surface.cols
  const height = surface.h / surface.rows

  u.fromArray(surface.u)
  v.fromArray(surface.v)
  n.fromArray(surface.n)

  position
    .fromArray(surface.o)
    .addScaledVector(u, (col + cols / 2) * width)
    .addScaledVector(v, (row + rows / 2) * height)

  if (origin) position.add(origin)

  target.makeBasis(u, v, n)
  target.scale(scale.set(cols * width, rows * height, surface.t))
  target.setPosition(position)
  return target
}

// Every cell of a surface, in index order. `visit` receives the piece index, the material
// name, and a matrix it must not hold on to -- the same one is reused for every cell.
export function eachCell(surface, origin, visit) {
  for (let row = 0; row < surface.rows; row += 1) {
    for (let col = 0; col < surface.cols; col += 1) {
      visit(
        pieceIndex(surface, row, col),
        materialAt(surface, row, col),
        cellMatrix(surface, row, col, matrix, origin),
        surface
      )
    }
  }
}

export function eachBuildingCell(building, visit) {
  const origin = new THREE.Vector3().fromArray(building.o)
  for (const surface of building.surfaces) eachCell(surface, origin, visit)
}
