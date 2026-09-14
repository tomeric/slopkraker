import { materialAt, pieceIndex } from "game/world/surface"

// Grouping a surface's cells into the slabs it falls apart into.
//
// A collapse that drops one body per cell reads as confetti: a one metre cube tumbling is
// neither masonry nor debris, and a house made of fourteen hundred of them is a swarm with
// the shape of a building. A storey-high wall section toppling as ONE slab reads as the
// thing it is. So before anything falls, the cells still standing are covered with
// rectangles, and each rectangle falls as a single body.
//
// THIS IS NOT `Game::Building::Blocks`, and it cannot be. Blocks are the polyomino tiling
// that decides what breaks TOGETHER when something hits it, and they are deliberately small
// and ragged so holes come out with a shape. Measured on the three-storey house: 299 blocks
// over 690 cells, and the floor and roof surfaces carry no blocks at all -- 764 of its 1398
// cells are their own piece. Falling through blocks would be 1063 units, a coarsening of
// 1.32, which is confetti with extra steps. These rectangles reach 356.
//
// Nothing here touches piece indices. A cell is still broken individually, still reported
// individually, and still numbered exactly as it always was; a chunk is only how the fall
// is drawn and simulated. That is what keeps this out of the client/server contract
// entirely -- the server has no idea slabs exist and does not need one.
//
// Two rules the rectangles obey, both of which fall out of what a slab has to BE:
//
//   - One material. A chunk is one body with one mass and one colour, so a brick wall and
//     the glass set into it cannot ride down together. This is also why walls fragment
//     more than floors do, and why going coarser than about 3x4 stops paying.
//   - Only what is standing. A wall you have already driven through falls around its hole
//     rather than sealing it up on the way down.
export function tileSurface(surface, { rows: maxRows, cols: maxCols }, standing) {
  const chunks = []
  const claimed = new Uint8Array(surface.rows * surface.cols)

  for (let row = 0; row < surface.rows; row += 1) {
    for (let col = 0; col < surface.cols; col += 1) {
      const at = row * surface.cols + col
      if (claimed[at]) continue

      const material = materialAt(surface, row, col)
      // A doorway holds an index and nothing else, so it can neither fall nor be grown
      // through. Claimed rather than skipped, so the scan never looks at it twice.
      if (material === "void" || !standing(pieceIndex(surface, row, col))) {
        claimed[at] = 1
        continue
      }

      // Widen first, then deepen by whole rows only. Rectangles rather than the maximal
      // polyomino: a slab is a cuboid collider, so anything that is not a rectangle would
      // have to be approximated by its bounding box, which would reach through the holes
      // it was grown around.
      let width = 1
      while (width < maxCols && col + width < surface.cols &&
             accepts(surface, row, col + width, claimed, material, standing)) {
        width += 1
      }

      let height = 1
      while (height < maxRows && row + height < surface.rows &&
             rowAccepts(surface, row + height, col, width, claimed, material, standing)) {
        height += 1
      }

      for (let r = 0; r < height; r += 1) {
        for (let c = 0; c < width; c += 1) claimed[(row + r) * surface.cols + col + c] = 1
      }

      chunks.push({ row, col, rows: height, cols: width, material, cells: width * height })
    }
  }

  return chunks
}

function accepts(surface, row, col, claimed, material, standing) {
  if (claimed[row * surface.cols + col]) return false
  if (materialAt(surface, row, col) !== material) return false
  return standing(pieceIndex(surface, row, col))
}

function rowAccepts(surface, row, col, width, claimed, material, standing) {
  for (let c = 0; c < width; c += 1) {
    if (!accepts(surface, row, col + c, claimed, material, standing)) return false
  }
  return true
}
