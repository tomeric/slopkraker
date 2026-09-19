module Game
  module Building
    # What stands between a dwelling and its street: a hedge along the road's edge, broken
    # at the garden path, and the lawn either side of the path.
    #
    # THE HEDGE IS PIECES. A hedge you cannot drive through is the one thing this game must
    # not have, and a piece is the only thing here that breaks, persists, and reveals to
    # every player alike. One surface per garden, one row of cells, the path's columns void
    # -- index space kept, geometry culled, exactly as a doorway is. It stands at storey -1
    # like rubble, so no collapse can weigh it or fell it, and it is left out of the
    # rubble's mix, because the wreckage of a house is not made of leaves.
    #
    # THE LAWN IS A PICTURE: rectangles the client drapes on the ground beside the road
    # ribbons, in the same mesh. Nothing about it is a piece, nothing about it crosses the
    # wire beyond these coordinates.
    module Gardens
      HEDGE_HEIGHT = 1.0
      HEDGE_THICKNESS = 0.5
      # How far in from the road's edge the hedge stands, and how wide the path from the
      # road to the door is. The path is whole cells, rounded up, because the hedge is cells.
      KERB = 0.4
      PATH = 1.2
      # The strip of lawn behind the footprint. A fixed depth for now; the BGT land cover is
      # the honest source and is the next pass.
      BACK = 5.0
      EAST = Vector3.new(1, 0, 0)
      UP = Vector3.new(0, 1, 0)

      # 7. One hedge per garden, in the order the gardens are listed.
      def self.hedges(row)
        row.gardens.map do |garden|
          d = row.dwellings.fetch(garden.bay)
          cols = Walls.cells(d.width, row.cell)
          Surface.new(
            kind: :hedge, storey: -1, material: Materials.fetch(:hedge),
            origin: Vector3.new(d.x0, 0.0, hedge_z(row, garden)), u: EAST, v: UP,
            width: d.width, height: HEDGE_HEIGHT, cols: cols, rows: 1, thickness: HEDGE_THICKNESS,
            patches: path_columns(row, garden.bay, cols).map { |c| Surface::Patch.new(col0: c, row0: 0, col1: c, row1: 0, material: :void) },
            seed: row.seed + 200 + garden.bay, bay: garden.bay
          )
        end
      end

      # The plane the hedge's thickness straddles: KERB in from the road's edge, then half
      # its own thickness, so its street face stands exactly KERB from the road.
      def self.hedge_z(row, garden)
        row.z0 - garden.depth + KERB + HEDGE_THICKNESS / 2.0
      end

      # The path is the door's columns widened to PATH, extending away from the end the
      # door stands near, PLUS the garage door's columns where the dwelling has one: a
      # garaged front has a drive, and a hedge grown across a garage door is a car walled
      # in. Asked of the very Openings object the front wall was punctured by, which is how
      # both are guaranteed to meet what they are openings for.
      def self.path_columns(row, bay, cols)
        d = row.dwellings.fetch(bay)
        openings = Openings.new(seed: row.seed + bay, style: :house, garage: d.garage)
        door = openings.door_columns(cols)
        return [] if door.empty?

        cell = d.width / cols
        wanted = [ (PATH / cell).ceil, 1 ].max
        extra = wanted - door.length
        path =
          if extra <= 0
            door
          else
            door.first < cols / 2 ? door + (door.last + 1..door.last + extra).to_a : (door.first - extra...door.first).to_a + door
          end
        (path + openings.garage_columns(cols)).select { |c| c.between?(0, cols - 1) }.uniq.sort
      end

      # Contiguous columns as `[first, last]` pairs. On every garaged front the estate has,
      # the path's widening meets the drive and the two come out as ONE run; the pairs are
      # here because nothing guarantees that -- a wider dwelling puts a pier between them,
      # and then the lawn has a strip in the middle to keep.
      def self.runs(columns)
        columns.chunk_while { |a, b| b == a + 1 }.map { |g| [ g.first, g.last ] }
      end

      # Rings in the row's own frame, closed, four points each: for each garden the lawn
      # either side of the path, then one strip behind the footprint. The client drapes
      # them on the ground. Empty for a row with no gardens.
      def self.lawns(row)
        return [] if row.gardens.empty?

        fronts = row.gardens.flat_map do |garden|
          d = row.dwellings.fetch(garden.bay)
          cols = Walls.cells(d.width, row.cell)
          cell = d.width / cols
          z0 = row.z0 - garden.depth
          z1 = row.z0
          # The lawn is what the hedge's voids leave: the strips between the ends of the
          # dwelling, the path and -- on a garaged front -- the drive. The edges alternate
          # lawn-start, lawn-end all the way across, so a garden with no voids is one rect,
          # and every garden the estate actually has is one or two.
          edges = [ 0, *runs(path_columns(row, garden.bay, cols)).flat_map { |a, b| [ a, b + 1 ] }, cols ]
          edges.each_slice(2).map { |a, b| rect(d.x0 + a * cell, z0, d.x0 + b * cell, z1) }.compact
        end
        back_z = row.footprint.map(&:last).max
        fronts + [ rect(row.x0, back_z, row.x1, back_z + BACK) ]
      end

      def self.rect(x0, z0, x1, z1)
        return nil if x1 - x0 < 0.05

        [ [ x0, z0 ], [ x1, z0 ], [ x1, z1 ], [ x0, z1 ] ]
      end
    end
  end
end
