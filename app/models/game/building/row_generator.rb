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
        # 7. Hedges after the boxes: a row that gains a garden keeps every index it had.
        built = dwellings(row) + boxes(row) + Gardens.hedges(row)
        surfaces = built + rubble(row, built)
        SurfaceSet.new(surfaces.map { |s| s.rotated(row.yaw) }, storey_count: row.storeys)
      end

      # The lawns, turned by the row's yaw exactly as its surfaces are, so the client can add
      # the building's position to them as it does to every surface origin.
      def self.lawns(row)
        row = Row.from(row) unless row.is_a?(Row)
        c = Math.cos(row.yaw)
        s = Math.sin(row.yaw)
        Gardens.lawns(row).map { |ring| ring.map { |x, z| [ (x * c - z * s).round(3), (x * s + z * c).round(3) ] } }
      end

      # 1 fronts and backs, 2 ends, 3 party walls, 4 interiors, 5 roof sections, 6 boxes,
      # 7 hedges, then rubble LAST.
      def self.dwellings(row)
        return [] if row.dwellings.empty?

        n = row.dwellings.length
        built = []
        row.dwellings.each_with_index do |d, i|
          openings = Openings.new(seed: row.seed + i, style: :house)
          row.storeys.times { |s| built << wall(row, [ d.x0, row.z0 ], [ d.x1, row.z0 ], storey: s, openings: openings, edge: 0, bay: i) }
          row.storeys.times { |s| built << wall(row, [ d.x1, row.z1 ], [ d.x0, row.z1 ], storey: s, openings: openings, edge: 2, bay: i) }
        end
        row.storeys.times { |s| built << wall(row, [ row.x1, row.z0 ], [ row.x1, row.z1 ], storey: s, openings: Openings.new(seed: row.seed + 7, style: :annex), edge: 1, bay: n - 1) }
        row.storeys.times { |s| built << wall(row, [ row.x0, row.z1 ], [ row.x0, row.z0 ], storey: s, openings: Openings.new(seed: row.seed + 11, style: :annex), edge: 3, bay: 0) }
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

      # How close to the row's rectangle an edge has to run before it counts as standing
      # against it, and how far apart two walls may be and still be the same wall. Both are
      # imported-geometry slack: a wall built twice in the same place is a wall that reads
      # as one and breaks as two.
      TOLERANCE = 0.5
      COINCIDENT = 0.4
      # A storey is only excused by something at least as tall as it. The slack is imported
      # geometry: eaves and storey heights that disagree by centimetres would otherwise put
      # up a second wall three centimetres proud of the first, which reads as one wall and
      # breaks as two.
      STOREY_SLACK = 0.3

      # 6. Boxes: annexes, sheds, garages, the parts of a church. Each wall is generated
      # once -- never where a box stands against the row, never inside a bigger box that
      # came before it, never twice where two boxes meet.
      def self.boxes(row)
        kept = []
        containers = []
        built = []
        row.boxes.each_with_index do |box, i|
          style = style_for(row, box)
          openings = style ? Openings.new(seed: row.seed + 100 + i, style: style) : nil
          edges(box.ring).each_with_index do |(from, to), e|
            # The three rules say whether a wall stands HERE. How much of it they excuse is a
            # HEIGHT, and taking that decision once for the box leaves a six-storey tower
            # open above the two-storey nave it stands against: every one of its storeys is
            # dropped by an edge only the bottom two are behind.
            covered = covered_to(row, from, to, kept, containers)
            storeys = box.storeys.times.reject { |s| (s + 1) * box.storey_height <= covered + STOREY_SLACK }
            next if storeys.empty?

            kept << [ from, to, box.storeys * box.storey_height ]
            storeys.each do |s|
              built << wall(row, from, to, storey: s, openings: openings, edge: box.door && e.zero? ? 0 : 1 + e,
                            bay: box.bay, storeys: box.storeys, storey_height: box.storey_height, seed: row.seed + 100 + i)
            end
          end
          # Per box rather than per edge, so these are unchanged: a deck is void where it
          # would lie inside the row or inside a box that came before it, whatever heights
          # the two stand at.
          box.storeys.times do |s|
            built << clipped_deck(box.ring, row.rect, containers, y: s * box.storey_height, cell: row.cell, kind: :floor,
                                  material: s.zero? ? :concrete : :timber, storey: s, thickness: Interior::DECK_THICKNESS, bay: box.bay)
          end
          built.concat box_roof(row, box, containers)
          containers << [ box.ring, box.eaves ]
        end
        built
      end

      # How high this edge is already walled by something else: the top of the row's own
      # walls where it runs along the row, an earlier box's eaves where it lies inside that
      # box, and the top of any wall already standing along the same line. Zero when nothing
      # stands against it, which builds every storey.
      def self.covered_to(row, from, to, kept, containers)
        heights = []
        heights << row.storeys * row.storey_height if row.rect && on_or_inside?(from, row.rect) && on_or_inside?(to, row.rect)
        containers.each { |ring, eaves| heights << eaves if inside_ring?(from, ring) && inside_ring?(to, ring) }
        kept.each { |a0, a1, top| heights << top if coincident?([ a0, a1 ], [ from, to ]) }
        heights.max || 0.0
      end

      # How a box is punctured, by what it is. A solid box -- a shed -- gets nothing; a
      # garage its door; a church's parts theirs, told apart by the roof the importer gave
      # them (a pyramid is a tower) and by which part carries the door (the nave); anything
      # else with a door is a house of its own, and anything without one an annex.
      def self.style_for(row, box)
        return nil if box.solid
        return :garage if box.door == "garage"

        if row.category == "church" || row.category == "hall"
          return :tower if box.roof == "pyramid"
          return box.door ? :nave : :chapel
        end
        box.door ? :house : :annex
      end

      def self.box_roof(row, box, containers)
        case box.roof
        when "gable"
          x0, z0, x1, z1 = box.bounds
          Roof.gable(rectangle(row, x0, x1, z0: z0, z1: z1, storeys: box.storeys, storey_height: box.storey_height,
                               eaves: box.eaves, ridge: box.ridge, roof: "gable")).map { |s| tagged(s, box.bay) }
        when "pyramid" then pyramid(box, row.cell)
        else
          [ clipped_deck(box.ring, row.rect, containers, y: box.eaves, cell: row.cell, kind: :roof, material: :concrete,
                         storey: box.storeys, thickness: Roof::THICKNESS, bay: box.bay) ]
        end
      end

      # A horizontal grid over the ring's box, void wherever a cell's centre falls outside
      # the ring or inside the row or an earlier box -- geometry culled, index space kept.
      # Void cells are merged into runs, one patch per run.
      def self.clipped_deck(ring, rect, containers, y:, cell:, kind:, material:, storey:, thickness:, bay:)
        xs = ring.map(&:first)
        zs = ring.map(&:last)
        x0, x1, z0, z1 = xs.min, xs.max, zs.min, zs.max
        cols = Walls.cells(x1 - x0, cell)
        rows = Walls.cells(z1 - z0, cell)
        cw = (x1 - x0) / cols
        ch = (z1 - z0) / rows
        patches = rows.times.flat_map do |r|
          void = cols.times.reject do |c|
            cx = x0 + (c + 0.5) * cw
            cz = z0 + (r + 0.5) * ch
            Rubble.contains?(ring, cx, cz) && !(rect && strictly_inside?([ cx, cz ], rect)) &&
              containers.none? { |other, _eaves| Rubble.contains?(other, cx, cz) }
          end
          void.slice_when { |a, b| b != a + 1 }.map { |run| Surface::Patch.new(col0: run.first, row0: r, col1: run.last, row1: r, material: :void) }
        end
        Surface.new(kind: kind, storey: storey, material: Materials.fetch(material), origin: Vector3.new(x0, y, z0), u: EAST, v: SOUTH,
                    width: x1 - x0, height: z1 - z0, cols: cols, rows: rows, thickness: thickness, patches: patches, bay: bay)
      end

      # Four triangular planes from the eaves of the ring's box to one apex. Each is a
      # rectangle clipped to its triangle with void, exactly as a gable end is: Roof.clip
      # already draws that triangle.
      def self.pyramid(box, cell)
        x0, z0, x1, z1 = box.bounds
        cx = (x0 + x1) / 2.0
        cz = (z0 + z1) / 2.0
        rise = [ box.ridge - box.eaves, 0.5 ].max
        corners = [ [ x0, z0 ], [ x1, z0 ], [ x1, z1 ], [ x0, z1 ] ]
        corners.each_with_index.map do |from, i|
          to = corners[(i + 1) % 4]
          along = Vector3.new(to[0] - from[0], 0.0, to[1] - from[1])
          mid = [ (from[0] + to[0]) / 2.0, (from[1] + to[1]) / 2.0 ]
          inward = Vector3.new(cx - mid[0], rise, cz - mid[1])
          # ODD, ALWAYS. Roof.clip judges a cell by its top edge, so the only cell of the
          # top row it keeps is one whose middle is exactly the apex -- and an even column
          # count puts the apex on a seam between two columns instead, which clips the whole
          # top row of all four planes away and leaves a square hole where the point should
          # be. A gable never showed it: its own last step is hidden under the overhang.
          cols = Walls.cells(along.length, cell)
          cols += 1 if cols.even?
          rows = [ Walls.cells(inward.length, cell), 1 ].max
          Surface.new(kind: :roof, storey: box.storeys, material: Materials.fetch(:roof_tile),
                      origin: Vector3.new(from[0], box.eaves, from[1]), u: along.normalised, v: inward.normalised,
                      width: along.length, height: inward.length, cols: cols, rows: rows, thickness: Roof::THICKNESS,
                      patches: Roof.clip(cols, rows), bay: box.bay)
        end
      end

      def self.edges(ring) = ring.each_with_index.map { |p, i| [ p, ring[(i + 1) % ring.length] ] }

      def self.on_or_inside?(p, rect, tol = TOLERANCE)
        x0, z0, x1, z1 = rect
        p[0] >= x0 - tol && p[0] <= x1 + tol && p[1] >= z0 - tol && p[1] <= z1 + tol
      end

      def self.strictly_inside?(p, rect, tol = 0.05)
        x0, z0, x1, z1 = rect
        p[0] > x0 + tol && p[0] < x1 - tol && p[1] > z0 + tol && p[1] < z1 - tol
      end

      def self.inside_ring?(p, ring, tol = TOLERANCE)
        Rubble.contains?(ring, p[0], p[1]) || Rubble.distance_to_ring(ring, p[0], p[1]) <= tol
      end

      # Two segments along one line, overlapping: the second is a wall that already exists.
      def self.coincident?(a, b, tol = COINCIDENT)
        (a0, a1), (b0, b1) = a, b
        dx, dz = a1[0] - a0[0], a1[1] - a0[1]
        length = Math.hypot(dx, dz)
        return false if length < 1e-6

        dir = [ dx / length, dz / length ]
        [ b0, b1 ].each do |p|
          off = (p[0] - a0[0]) * -dir[1] + (p[1] - a0[1]) * dir[0]
          return false if off.abs > tol
        end
        t0 = (b0[0] - a0[0]) * dir[0] + (b0[1] - a0[1]) * dir[1]
        t1 = (b1[0] - a0[0]) * dir[0] + (b1[1] - a0[1]) * dir[1]
        [ t0, t1 ].max > tol && [ t0, t1 ].min < length - tol
      end

      # Sutherland-Hodgman against one half-plane: the part of `ring` where coordinate
      # `axis` (0 for x, 1 for z) is >= `at` (side +1) or <= `at` (side -1). The importer
      # uses it to split a dwelling that reaches past the band.
      def self.clip(ring, axis, at, side)
        out = []
        ring.each_with_index do |p, i|
          q = ring[(i + 1) % ring.length]
          pin = (p[axis] - at) * side >= 0
          qin = (q[axis] - at) * side >= 0
          out << p if pin
          next unless pin != qin

          t = (at - p[axis]) / (q[axis] - p[axis])
          out << [ p[0] + t * (q[0] - p[0]), p[1] + t * (q[1] - p[1]) ]
        end
        out
      end

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
