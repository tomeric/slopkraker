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
      # door stands near. Asked of the very Openings object the front wall was punctured by,
      # which is how the path is guaranteed to meet the door.
      def self.path_columns(row, bay, cols)
        openings = Openings.new(seed: row.seed + bay, style: :house)
        door = openings.door_columns(cols)
        return [] if door.empty?

        cell = row.dwellings.fetch(bay).width / cols
        wanted = [ (PATH / cell).ceil, 1 ].max
        extra = wanted - door.length
        return door if extra <= 0

        columns = door.first < cols / 2 ? door + (door.last + 1..door.last + extra).to_a : (door.first - extra...door.first).to_a + door
        columns.select { |c| c.between?(0, cols - 1) }
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
          path = path_columns(row, garden.bay, cols)
          z0 = row.z0 - garden.depth
          z1 = row.z0
          if path.empty?
            [ rect(d.x0, z0, d.x1, z1) ]
          else
            px0 = d.x0 + path.min * cell
            px1 = d.x0 + (path.max + 1) * cell
            [ rect(d.x0, z0, px0, z1), rect(px1, z0, d.x1, z1) ].reject { |ring| ring.nil? }
          end
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
