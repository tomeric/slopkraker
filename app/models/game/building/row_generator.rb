module Game
  module Building
    # A Row in, a SurfaceSet out. Built in the row's frame from the same modules a single
    # house is built from, then every surface is turned by the row's yaw.
    #
    # THE ORDER BELOW IS THE CONTRACT, exactly as it is in Generator: offsets are handed
    # out by walking the surfaces in sequence, so a reordering renumbers every piece after
    # it and damage recorded against one wall comes back applied to another. The worked
    # example in row_test pins it.
    module RowGenerator
      UP = Vector3.new(0, 1, 0)
      EAST = Vector3.new(1, 0, 0)
      SOUTH = Vector3.new(0, 0, 1)
      # Only the row's ends get one; a section in the middle meets its neighbour flush.
      OVERHANG = Roof::OVERHANG

      def self.call(row)
        row = Row.from(row) unless row.is_a?(Row)
        built = dwellings(row) + boxes(row)
        surfaces = built + rubble(row, built)
        SurfaceSet.new(surfaces.map { |s| s.rotated(row.yaw) }, storey_count: row.storeys)
      end

      # 1 fronts and backs, 2 ends, 3 party walls, 4 interiors, 5 roof sections.
      def self.dwellings(row)
        return [] if row.dwellings.empty?

        n = row.dwellings.length
        built = []
        row.dwellings.each_with_index do |d, i|
          openings = Openings.new(seed: row.seed + i)
          row.storeys.times { |s| built << wall(row, [ d.x0, row.z0 ], [ d.x1, row.z0 ], storey: s, openings: openings, edge: 0, bay: i) }
          row.storeys.times { |s| built << wall(row, [ d.x1, row.z1 ], [ d.x0, row.z1 ], storey: s, openings: openings, edge: 2, bay: i) }
        end
        row.storeys.times { |s| built << wall(row, [ row.x1, row.z0 ], [ row.x1, row.z1 ], storey: s, openings: Openings.new(seed: row.seed + 7), edge: 1, bay: n - 1) }
        row.storeys.times { |s| built << wall(row, [ row.x0, row.z1 ], [ row.x0, row.z0 ], storey: s, openings: Openings.new(seed: row.seed + 11), edge: 3, bay: 0) }
        row.party_lines.each_with_index do |x, i|
          row.storeys.times { |s| built << wall(row, [ x, row.z0 ], [ x, row.z1 ], storey: s, openings: nil, edge: 5, between: [ i, i + 1 ]) }
        end
        row.dwellings.each_with_index { |d, i| built.concat Interior.build(rectangle(row, d.x0, d.x1)).map { |s| tagged(s, i) } }
        row.dwellings.each_with_index { |d, i| built.concat roof_section(row, d, i) }
        built
      end

      def self.wall(row, from, to, storey:, openings:, edge:, bay: 0, between: nil, storeys: row.storeys, storey_height: row.storey_height, seed: row.seed)
        along = Vector3.new(to[0] - from[0], 0.0, to[1] - from[1])
        cols = Walls.cells(along.length, row.cell)
        rows = Walls.cells(storey_height, row.cell)
        Surface.new(
          kind: :wall, storey: storey, material: Materials.fetch(:brick),
          origin: Vector3.new(from[0], storey * storey_height, from[1]), u: along.normalised, v: UP,
          width: along.length, height: storey_height, cols: cols, rows: rows, thickness: Walls::THICKNESS,
          patches: openings ? openings.for_wall(edge: edge, storey: storey, cols: cols, rows: rows) : [],
          seed: seed, bay: bay, between: between
        )
      end

      # A single-house Recipe over a rectangle of the row, so Interior and Roof can be
      # reused exactly as they are.
      def self.rectangle(row, x0, x1, z0: row.z0, z1: row.z1, storeys: row.storeys, storey_height: row.storey_height, eaves: row.eaves, ridge: row.ridge, roof: row.roof)
        Recipe.from(
          footprint: [ [ x0, z0 ], [ x1, z0 ], [ x1, z1 ], [ x0, z1 ] ],
          storeys: storeys, storey_height: storey_height, eaves: eaves, ridge: [ ridge, eaves ].max,
          roof: roof == "pyramid" ? "flat" : roof, cell: row.cell, seed: row.seed
        )
      end

      def self.tagged(surface, bay)
        Surface.new(
          kind: surface.kind, storey: surface.storey, material: surface.material, origin: surface.origin, u: surface.u, v: surface.v,
          width: surface.width, height: surface.height, cols: surface.cols, rows: surface.rows, thickness: surface.thickness,
          patches: surface.patches, seed: surface.seed, mix: surface.mix, bay: bay
        )
      end

      # This dwelling's share of one roof: two planes cut at the party lines, the ridge
      # along the row, an overhang only at the row's ends, and a gable end on the first
      # and the last dwelling. Flat: one deck per dwelling.
      def self.roof_section(row, d, i)
        return [ tagged(Roof.flat(rectangle(row, d.x0, d.x1)), i) ] if row.roof == "flat"

        first = i.zero?
        last = i == row.dwellings.length - 1
        run = row.depth / 2.0
        slope = Math.hypot(run, row.rise)
        start = d.x0 - (first ? OVERHANG : 0.0)
        span = d.width + (first ? OVERHANG : 0.0) + (last ? OVERHANG : 0.0)
        planes = [ 1, -1 ].map do |side|
          origin = Vector3.new(start, row.eaves, side.positive? ? row.z0 : row.z1)
          up_slope = Vector3.new(0.0, row.rise, side * run)
          Surface.new(
            kind: :roof, storey: row.storeys, material: Materials.fetch(:roof_tile),
            origin: origin, u: EAST, v: up_slope.normalised, width: span, height: slope,
            cols: Walls.cells(span, row.cell), rows: Walls.cells(slope, row.cell), thickness: Roof::THICKNESS, bay: i
          )
        end
        ends = []
        ends << gable_end(row, d.x0, i) if first
        ends << gable_end(row, d.x1, i) if last
        planes + ends
      end

      def self.gable_end(row, x, bay)
        cols = Walls.cells(row.depth, row.cell)
        rows = [ Walls.cells(row.rise, row.cell), 1 ].max
        Surface.new(
          kind: :gable, storey: row.storeys, material: Materials.fetch(:brick),
          origin: Vector3.new(x, row.eaves, row.z0), u: SOUTH, v: UP, width: row.depth, height: row.rise,
          cols: cols, rows: rows, thickness: Roof::GABLE_THICKNESS, patches: Roof.clip(cols, rows), seed: row.seed, bay: bay
        )
      end

      def self.boxes(row) = []   # Task 6

      # LAST. Over the union footprint, and each heap tagged with the dwelling whose
      # x-interval its centre falls in -- or, in a row of boxes, the nearest box's bay.
      def self.rubble(row, built)
        surface = Rubble.build(rectangle_for_footprint(row), built).first
        bays = surface.rows.times.flat_map do |r|
          surface.cols.times.map do |c|
            x = surface.origin.x + (c + 0.5) * surface.cell_width
            z = surface.origin.z + (r + 0.5) * surface.cell_height
            bay_at(row, x, z)
          end
        end
        [ Surface.new(
          kind: :rubble, storey: -1, material: surface.material, origin: surface.origin, u: surface.u, v: surface.v,
          width: surface.width, height: surface.height, cols: surface.cols, rows: surface.rows, thickness: surface.thickness,
          patches: surface.patches, seed: surface.seed, mix: surface.mix, bays: bays
        ) ]
      end

      def self.rectangle_for_footprint(row)
        Recipe.from(footprint: row.footprint, storeys: [ row.storeys, 1 ].max, storey_height: row.storey_height,
                    eaves: row.eaves, ridge: [ row.ridge, row.eaves ].max, roof: "flat", cell: row.cell, seed: row.seed)
      end

      def self.bay_at(row, x, z)
        if row.dwellings.any?
          lines = row.party_lines
          lines.index { |line| x < line } || row.dwellings.length - 1
        else
          nearest = row.boxes.each_with_index.min_by { |box, _| bx0, bz0, bx1, bz1 = box.bounds; Math.hypot(((bx0 + bx1) / 2.0) - x, ((bz0 + bz1) / 2.0) - z) }
          nearest ? nearest.first.bay : 0
        end
      end
    end
  end
end
