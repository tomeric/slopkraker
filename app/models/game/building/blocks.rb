module Game
  module Building
    # Tiles a surface's grid with polyominoes, so what breaks is a shape rather than a
    # square.
    #
    # The grid itself does not move. It is the index space, the collider unit and the
    # instancing unit all at once, and pieces of arbitrary outline would cost all three.
    # What changes is which cells share a fate: a block is a handful of neighbouring cells
    # that break together, so the edge left behind follows the block outlines and comes out
    # ragged.
    #
    # Two rules the tiling has to respect:
    #
    # A block never spans two materials. A window grouped with the brick around it would
    # take half a wall out when it broke, and a pane is supposed to be a pane -- which is
    # also why glass ends up as singles without anything special being said about it.
    #
    # And it is deterministic from the surface's own seed. Two clients that disagree about
    # which cells belong together would disagree about what a single hit destroyed.
    module Blocks
      # Offsets are [column, row] from the block's origin cell. Kept small deliberately:
      # at 1m cells a five-cell block is already five metres of wall.
      SHAPES = [
        # Square, and the two straight runs.
        [ [ 0, 0 ], [ 1, 0 ], [ 0, 1 ], [ 1, 1 ] ],
        [ [ 0, 0 ], [ 1, 0 ], [ 2, 0 ] ],
        [ [ 0, 0 ], [ 0, 1 ], [ 0, 2 ] ],
        # The bends, which are what stop a wall reading as courses of dominoes.
        [ [ 0, 0 ], [ 0, 1 ], [ 1, 1 ] ],
        [ [ 0, 0 ], [ 1, 0 ], [ 1, 1 ] ],
        [ [ 0, 0 ], [ 1, 0 ], [ 0, 1 ] ],
        [ [ 0, 0 ], [ 1, 0 ], [ 1, 1 ], [ 2, 1 ] ],
        [ [ 0, 0 ], [ 1, 0 ], [ 2, 0 ], [ 1, 1 ] ],
        # Pairs, which fill the gaps the larger shapes leave.
        [ [ 0, 0 ], [ 1, 0 ] ],
        [ [ 0, 0 ], [ 0, 1 ] ]
      ].freeze

      SINGLE = [ [ 0, 0 ] ].freeze

      # Which surfaces are worth blocking. A roof is tiles and a floor is a slab; both are
      # already made of small things and gain nothing from being grouped.
      BLOCKED_KINDS = %i[wall partition gable].freeze

      # A block id per cell, row-major, or nil for a surface that keeps its plain grid.
      # Ids are local to the surface -- the client offsets them by the surface's own piece
      # offset, the same way it does with everything else here.
      def self.tile(surface, seed:)
        return nil unless BLOCKED_KINDS.include?(surface.kind)

        cols = surface.cols
        rows = surface.rows
        assigned = Array.new(cols * rows)
        random = Random.new(seed + surface.piece_offset)
        next_id = 0

        rows.times do |row|
          cols.times do |col|
            index = row * cols + col
            next if assigned[index]

            cells = place(surface, assigned, cols, rows, col, row, random)
            cells.each { |cell| assigned[cell] = next_id }
            next_id += 1
          end
        end

        assigned
      end

      # The first shape that fits entirely on unclaimed cells of the same material. Shapes
      # are tried largest-first in a shuffled order, so the tiling varies without ever
      # leaving a cell behind: a single always fits.
      def self.place(surface, assigned, cols, rows, col, row, random)
        material = surface.material_at(row, col).name

        SHAPES.shuffle(random: random).each do |shape|
          cells = cells_for(surface, assigned, cols, rows, col, row, shape, material)
          return cells if cells
        end

        [ row * cols + col ]
      end

      def self.cells_for(surface, assigned, cols, rows, col, row, shape, material)
        cells = []

        shape.each do |dcol, drow|
          c = col + dcol
          r = row + drow
          return nil if c >= cols || r >= rows

          index = r * cols + c
          return nil if assigned[index]
          return nil if surface.material_at(r, c).name != material

          cells << index
        end

        cells
      end
    end
  end
end
