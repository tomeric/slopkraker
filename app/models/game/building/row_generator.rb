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

      # 1 fronts and backs, 2 ends, 3 party walls, 4 interiors, 5 roof sections, 5b dormers,
      # 5c chimneys, 6 boxes, 7 hedges, rubble LAST.
      def self.dwellings(row)
        return [] if row.dwellings.empty?

        n = row.dwellings.length
        built = []
        # WHERE EVERY DWELLING'S PARTITION LANDS, asked of the module that decides where it
        # stands. `rectangle(row, d.x0, d.x1)` is exactly what step 4 hands `Interior`, so
        # the columns kept clear of glass are worked out from the same line the slab is
        # drawn on -- and a row now gets the one answer a free-standing house's `Walls`
        # gets, by the same arithmetic, rather than a second and blunter one of its own.
        # A fraction range per EDGE of that rectangle, in its own order: 0 is the
        # dwelling's front, 2 its back, 1 the wall at x1 and 3 the wall at x0.
        reaches = row.dwellings.map { |d| Interior.partition_reach(rectangle(row, d.x0, d.x1)) }
        row.dwellings.each_with_index do |d, i|
          openings = Openings.new(seed: row.seed + i, style: :house, garage: d.garage, glazing: d.glazing)
          row.storeys.times { |s| built << wall(row, [ d.x0, row.z0 ], [ d.x1, row.z0 ], storey: s, openings: openings, edge: 0, bay: i, outward: -1, crossed: [ reaches[i][0] ]) }
          row.storeys.times { |s| built << wall(row, [ d.x1, row.z1 ], [ d.x0, row.z1 ], storey: s, openings: openings, edge: 2, bay: i, outward: -1, crossed: [ reaches[i][2] ]) }
        end
        # The two end walls are edges of the first and the last dwelling's rectangle, and
        # run the same way round: the partition that reaches ALONG the row lands on them.
        row.storeys.times { |s| built << wall(row, [ row.x1, row.z0 ], [ row.x1, row.z1 ], storey: s, openings: Openings.new(seed: row.seed + 7, style: :annex), edge: 1, bay: n - 1, outward: -1, crossed: [ reaches.last[1] ]) }
        row.storeys.times { |s| built << wall(row, [ row.x0, row.z1 ], [ row.x0, row.z0 ], storey: s, openings: Openings.new(seed: row.seed + 11, style: :annex), edge: 3, bay: 0, outward: -1, crossed: [ reaches.first[3] ]) }
        row.party_lines.each_with_index do |x, i|
          # A party wall has no outside at all -- it stands between two dwellings -- so it
          # gets no rainwater goods (a downpipe here runs full storey height INSIDE the
          # terrace, which is 52 of geleen's 911) and `outward` is moot rather than
          # meaningful: -1 because every wall needs some value, and this is the one every
          # hand-laid ring already uses.
          row.storeys.times { |s| built << wall(row, [ x, row.z0 ], [ x, row.z1 ], storey: s, openings: nil, edge: 5, between: [ i, i + 1 ], outward: -1, fittings: false) }
        end
        row.dwellings.each_with_index { |d, i| built.concat Interior.build(rectangle(row, d.x0, d.x1)).map { |s| tagged(s, i) } }
        row.dwellings.each_with_index { |d, i| built.concat roof_section(row, d, i); built.concat dormer(row, d, i); built.concat chimney(row, d, i) }
        built
      end

      def self.wall(row, from, to, storey:, openings:, edge:, bay: 0, between: nil, storeys: row.storeys, storey_height: row.storey_height, seed: row.seed, outward: -1, fittings: true, crossed: [], except: nil)
        along = Vector3.new(to[0] - from[0], 0.0, to[1] - from[1])
        cols = Walls.cells(along.length, row.cell)
        rows = Walls.cells(storey_height, row.cell)
        # The corners always, because a ring closes and every edge meets another at both
        # ends. Then every other stretch of this wall something lands on: the partition the
        # caller hands down, and everything else this row has standing, which is asked for
        # here rather than passed in because a box and a terrace are both facts about the
        # ROW and every wall the row builds is behind the same ones. Both arrive as fraction
        # ranges and `Walls.columns` turns them into columns against THIS grid -- `cols` is
        # rounded off the wall's own length, and a second place rounding a second length is
        # how two answers to one question start disagreeing by a cell.
        reserved = [ 0, cols - 1 ]
        if openings
          spans = crossed + behind(row, from, to, storey: storey, storey_height: storey_height, rows: rows, outward: outward, except: except)
          spans.each { |span| reserved |= Walls.columns(span, cols) }
        end
        Surface.new(
          kind: :wall, storey: storey, material: Materials.fetch(:brick),
          origin: Vector3.new(from[0], storey * storey_height, from[1]), u: along.normalised, v: UP,
          width: along.length, height: storey_height, cols: cols, rows: rows, thickness: Walls::THICKNESS,
          patches: openings ? openings.for_wall(edge: edge, storey: storey, cols: cols, rows: rows, reserved: reserved) : [],
          seed: seed, bay: bay, between: between, outward: outward, fittings: fittings
        )
      end

      # How far past a wall's own outer face something else of the row -- a box, or the
      # terrace -- has to reach to be standing against it: half the wall, and a centimetre
      # more so that a ring laid flush with the wall's line, which is how the importer
      # writes an annexe that touches the house, comes out inside the ring rather than
      # exactly on its boundary.
      AGAINST = Walls::THICKNESS / 2 + 0.01
      # Two rings grazing each other at a corner is not a wall in front of a window, and a
      # crossing of a few microns rounds down into a column all the same. Shorter than this
      # and nothing is standing against anything.
      GRAZE = 0.05

      # WHICH STRETCHES OF THIS WALL SOMETHING ELSE OF THIS ROW STANDS BEHIND, as fraction
      # ranges along it -- the same currency `Interior.partition_reach` answers in, so
      # `wall` turns the two into columns the one way. An annexe, a shed or a church wing
      # built against a row's front, back or end covers that part of the face, and a window
      # there glazes into its brick. Measured over every world before this: 228 panes on a
      # row's own faces had a box behind them, 153 of them wholly behind one, over 22 of the
      # 48 rows -- worst church-row-10 at 31 and church-row-6 at 28. The hand-made worlds
      # have no boxes and no row recipes, so none of this reaches them.
      #
      # AND THE TERRACE IS ONE OF THE SOLIDS, not just the boxes. The question is about the
      # space immediately outside a wall, and it is the same question whichever of this
      # row's walls is asking: a box wall standing against the terrace has the terrace's
      # brick behind its glass exactly as a terrace wall standing against a box has the
      # box's. Nothing but `covered_to` said so before, and `covered_to` drops an edge only
      # where the row swallows it WHOLE -- so an edge with one end inside the row's
      # rectangle and one outside kept its whole wall, and the stretch of it lying against
      # the terrace kept its windows. Measured over all five worlds: 26 panes on 10 of
      # geleen's 48 rows, 20 of them wholly behind two storeys of terrace.
      #
      # BUILT AGAINST THE FACE, never merely overlapping the footprint. The question asked
      # is whether the box occupies the space immediately OUTSIDE this wall, so the wall's
      # own line is pushed out by AGAINST before the ring is asked. A shed that laps over
      # the row's outline and stops short of its outer skin is inside the building rather
      # than in front of it and hides no window -- two panes on geleen are exactly that,
      # and they keep their glass.
      #
      # ONLY THE STOREYS THE BOX REACHES, and the bar is the SILL rather than the floor or
      # the ceiling. A one-storey shed hides the ground floor of the two-storey house
      # behind it and nothing above it; the bedroom window over the shed roof is a window,
      # not a fault, and a shed 3 cm taller than the storey below it must not blank that
      # bedroom. But a box whose wall rises into the course the glass sits on IS behind that
      # glass, however little of it -- which is the same bar the partition is held to, where
      # a slab touching any part of a column reserves the whole column. A box's walls stop
      # at its eaves, and `Openings#sill` puts the glass one course above the floor, so that
      # course is the line and not the middle of the storey: measured with the middle, four
      # panes of geleen kept their glass with a flat annexe roof across the bottom third of
      # them.
      def self.behind(row, from, to, storey:, storey_height:, rows:, outward:, except: nil)
        solids = standing(row, except)
        return [] if solids.empty?

        dx, dz = to[0] - from[0], to[1] - from[1]
        length = Math.hypot(dx, dz)
        return [] if length < 1e-6

        # A wall's own normal is u x v = (-u.z, 0, u.x) with v = UP, and `outward` is the
        # sign that turns that into the direction pointing away from the building: see
        # Walls.outward, which is where a box's own ring winding is read off.
        push = AGAINST * outward
        nx = -dz / length * push
        nz = dx / length * push
        a = [ from[0] + nx, from[1] + nz ]
        b = [ to[0] + nx, to[1] + nz ]
        sill = (storey + [ Openings::SILL_ROW, rows - 1 ].min.fdiv(rows)) * storey_height

        solids.flat_map do |ring, top, (x0, z0, x1, z1)|
          next [] if top <= sill
          next [] if [ a[0], b[0] ].min > x1 || [ a[0], b[0] ].max < x0
          next [] if [ a[1], b[1] ].min > z1 || [ a[1], b[1] ].max < z0

          spans_inside(a, b, ring, length)
        end
      end

      # EVERYTHING THIS ROW HAS STANDING that a wall of it could be built in front of, as
      # `[ring, the top of its walls, its bounds]`: every box but the one this wall belongs
      # to, and the terrace itself.
      #
      # The terrace needs no `except` of its own, and that is geometry rather than luck. A
      # row's rectangle is CONVEX and every wall the row puts up -- a dwelling's front or
      # back, either end -- is one of its four sides with `outward` pointing away from it,
      # so the probe below can never land back inside the rectangle it started on. A box's
      # ring promises neither: it is imported, it can be concave, and a probe a hand's
      # breadth outside one of its edges can land inside another part of the same ring,
      # which is what `except:` is for. A party wall stands INSIDE the rectangle and would
      # reserve every column of itself -- correctly, it has a dwelling on both sides -- but
      # it is built with no openings at all and never reaches here.
      def self.standing(row, except)
        solids = row.boxes.reject { |box| box.equal?(except) }.map { |box| [ box.ring, box.eaves, box.bounds ] }
        return solids unless row.rect

        x0, z0, x1, z1 = row.rect
        solids << [ [ [ x0, z0 ], [ x1, z0 ], [ x1, z1 ], [ x0, z1 ] ], row.storeys * row.storey_height, row.rect ]
      end

      # The stretches of the segment a -> b that lie inside the ring, as fraction ranges.
      # Cut the segment wherever it crosses an edge of the ring and keep the pieces whose
      # middle is inside: exact for a ring of any shape, where sampling the wall at some
      # spacing would step over a thin wing and a per-column centre test would miss a box
      # that covers most of a column without covering the middle of it.
      def self.spans_inside(a, b, ring, length)
        dx, dz = b[0] - a[0], b[1] - a[1]
        cuts = [ 0.0, 1.0 ]
        edges(ring).each do |p, q|
          t = crossing(a, dx, dz, p, q)
          cuts << t if t
        end
        cuts.sort.each_cons(2).filter_map do |t0, t1|
          next if (t1 - t0) * length < GRAZE

          middle = (t0 + t1) / 2
          next unless Rubble.contains?(ring, a[0] + dx * middle, a[1] + dz * middle)

          [ t0, t1 ]
        end
      end

      # How far along a -> b it crosses the segment p -> q, or nil where the two are
      # parallel or the crossing falls off the end of either.
      def self.crossing(a, dx, dz, p, q)
        sx, sz = q[0] - p[0], q[1] - p[1]
        cross = dx * sz - dz * sx
        return nil if cross.abs <= Interior::PARALLEL * Math.hypot(dx, dz) * Math.hypot(sx, sz)

        ox, oz = p[0] - a[0], p[1] - a[1]
        t = (ox * sz - oz * sx) / cross
        u = (ox * dz - oz * dx) / cross
        t.between?(0.0, 1.0) && u.between?(0.0, 1.0) ? t : nil
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

      # Rebuilds a surface with a bay on it. EVERY keyword Surface takes has to be carried
      # here or it silently reverts to its default: today only floors, partitions, roofs and
      # gables come through, all of them at the defaults, so a dropped keyword changes
      # nothing -- which is exactly the long fuse this codebase keeps finding. Carry them.
      def self.tagged(surface, bay)
        Surface.new(
          kind: surface.kind, storey: surface.storey, material: surface.material, origin: surface.origin, u: surface.u, v: surface.v,
          width: surface.width, height: surface.height, cols: surface.cols, rows: surface.rows, thickness: surface.thickness,
          patches: surface.patches, seed: surface.seed, mix: surface.mix, bay: bay,
          between: surface.between, bays: surface.bays, fittings: surface.fittings, outward: surface.outward,
          capped: surface.capped
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
        sun = sun_facing_side(row.yaw)
        # A dakkapel always stands on the FRONT plane, and the sun is on the front plane half
        # the time, so half of a flagged-and-dormered dwelling's arrays would be drawn UNDER
        # the dormer: measured before this, estate-row-1 bay 0 had 72% of its array (5.09 of
        # 7.08 m2) swallowed and church-row-6 bay 0 52%. The array starts above the dormer's
        # reach instead, and is dropped when too little plane is left above it.
        dakkapel = dormer_plan(row, d)
        planes = [ 1, -1 ].map do |side|
          origin = Vector3.new(start, row.eaves, side.positive? ? row.z0 : row.z1)
          up_slope = Vector3.new(0.0, row.rise, side * run)
          cols = Walls.cells(span, row.cell)
          rows = Walls.cells(slope, row.cell)
          floor = dakkapel && side == DORMER_SIDE ? dormer_rows(dakkapel, run: run, slope: slope, rows: rows) : 0
          # Panels on the sun-facing slope of a flagged dwelling, and on nothing else.
          panels = d.solar && side == sun ? Array(solar_patch(cols, rows, floor: floor)) : []
          # And the hole the dakkapel stands over, LAST so that it wins: the last patch
          # covering a cell decides it, and a cell inside the dormer box has no roof in it to
          # put a panel on. The two cannot meet today -- `floor` starts the array above the
          # dormer's own reach, which is rounded UP where this rounds down -- and ordering
          # them says which is right if they ever do.
          hole = dakkapel && side == DORMER_SIDE ? Array(dormer_void(dakkapel, origin_x: origin.x, cols: cols, rows: rows, width: span, height: slope, run: run)) : []
          Surface.new(
            kind: :roof, storey: row.storeys, material: Materials.fetch(:roof_tile),
            origin: origin, u: EAST, v: up_slope.normalised, width: span, height: slope,
            cols: cols, rows: rows, thickness: Roof::THICKNESS, patches: panels + hole, bay: i
          )
        end
        ends = []
        ends << gable_end(row, d.x0, i) if first
        ends << gable_end(row, d.x1, i) if last
        planes + ends
      end

      # Which of the two roof planes faces the sun, as the `side` roof_section builds them
      # with. Game +z is SOUTH -- Terrain::Frame#to_game negates RD north -- and in the
      # row's own frame the back plane (side -1) faces +z while the front (side +1) faces
      # -z; a rotation by yaw sends local +z to a world z of cos(yaw). So the back plane
      # is the sun-facing one exactly when cos(yaw) is positive.
      #
      # Derived from the yaw and never from `surface.normal`: both planes are built with
      # u = EAST, so the front plane's u x v points INTO the roof and the two normals do
      # not mean the same thing.
      def self.sun_facing_side(yaw)
        Math.cos(yaw).positive? ? -1 : 1
      end

      # The panels, as a patch of `solar` cells centred on the plane and inset from its
      # edges. A patch, so a roof of panels is the same surfaces and the same indices as a
      # roof of tiles -- and a broken panel is a broken roof cell, which is what it is.
      #
      # `floor` is the first row the array may start on, which is the inset everywhere
      # except the plane a dakkapel stands on: see roof_section.
      def self.solar_patch(cols, rows, floor: 0)
        across = cols - 2 * SOLAR_INSET
        bottom = [ SOLAR_INSET, floor ].max
        up = rows - SOLAR_INSET - bottom
        # Below three clear cells in either direction the array would be a sliver -- one
        # or two panels rather than a rectangle -- so a plane that narrow gets none, not a
        # shrunk one. (Design doc §2: "none at all if the plane has fewer than three
        # columns or three rows after the inset.") The SAME judgement decides what is left
        # above a dormer, rather than a second threshold that could drift from this one --
        # and three clear rows is stricter than the SOLAR_ROWS an array actually needs.
        return nil if across < 3 || up < 3

        width = [ SOLAR_COLS, across ].min
        height = [ SOLAR_ROWS, up ].min
        col0 = SOLAR_INSET + (across - width) / 2
        row0 = bottom + (up - height) / 2
        Surface::Patch.new(col0: col0, row0: row0, col1: col0 + width - 1, row1: row0 + height - 1, material: :solar)
      end

      def self.gable_end(row, x, bay)
        cols = Walls.cells(row.depth, row.cell)
        rows = [ Walls.cells(row.rise, row.cell), 1 ].max
        Surface.new(
          kind: :gable, storey: row.storeys, material: Materials.fetch(:brick),
          origin: Vector3.new(x, row.eaves, row.z0), u: SOUTH, v: UP, width: row.depth, height: row.rise,
          cols: cols, rows: rows, thickness: Roof::GABLE_THICKNESS, patches: Roof.clip(cols, rows), capped: true,
          seed: row.seed, bay: bay
        )
      end

      # A dakkapel: a box standing on the front roof plane with a window the width of the
      # box, white cheeks and a zinc top. Everything here is metres in the row's frame and
      # decided by four constants, so a dormer on a 1987 terrace is the size a 1987 dormer
      # is and never a random one.
      DORMER_WIDTH = 3.0
      DORMER_HEIGHT = 1.5
      # How far in from the eaves line the front face stands.
      DORMER_SETBACK = 1.0
      # The top has to meet the roof this far below the ridge, or the dormer is a second
      # ridge. The importer checks the same sum before it flags a dwelling.
      DORMER_CLEARANCE = 0.5
      DORMER_MIN_WIDTH = 1.5
      # Zinc sheet on boards, not a steel slab: at Roof::THICKNESS the deck weighs 1560
      # kg/m2 against the main roof's 380, which makes a dakkapel the heaviest thing on the
      # house -- it would condemn a flagged dwelling earlier than its neighbour and fall as
      # one eight-tonne body.
      DORMER_TOP_THICKNESS = 0.05

      # A solar array: at most this many cells across and up, inset this far from every edge
      # of the plane so the array never runs into the ridge, the eaves or the verge.
      SOLAR_COLS = 4
      SOLAR_ROWS = 2
      SOLAR_INSET = 1

      # 5b. Four surfaces, or none: the front (glass in every cell, because a dakkapel is a
      # window), two cheeks (plaster, rectangles whose lower rear corner lies inside the roof
      # and is never seen) and the flat top (steel). The front's foot is ON the roof plane, at
      # `eaves + rise * setback / run`; the top is DORMER_HEIGHT above it, and the roof
      # reaches that height `height * run / rise` further back, which is where the cheeks
      # and the top end. Above every storey and in the dwelling's bay, like its roof, so
      # it falls with the dwelling.
      # A dakkapel stands on the plane at z0, which roof_section builds as `side` +1.
      DORMER_SIDE = 1

      # The dakkapel this dwelling gets, or nil for none: where it starts along the row, how
      # wide it is and how far back up the roof it reaches, behind the three gates that
      # decide whether there is one at all. Pulled out of `dormer` so roof_section can ask
      # the same question the builder answers, rather than re-deriving the gates and drifting
      # from them -- and it carries `x0` for the same reason: the footprint the void patch is
      # cut to and the footprint the cheeks stand on have to be one calculation, or the hole
      # and the box that covers it can part company.
      def self.dormer_plan(row, d)
        return nil unless d.dormer && row.roof == "gable" && row.rise.positive?

        run = row.depth / 2.0
        width = [ DORMER_WIDTH, d.width - 2.0 ].min
        return nil if width < DORMER_MIN_WIDTH

        depth = DORMER_HEIGHT * run / row.rise
        return nil if DORMER_SETBACK + depth > run - DORMER_CLEARANCE

        { width: width, depth: depth, x0: d.x0 + (d.width - width) / 2.0 }
      end

      # The roof the dakkapel stands over, as ONE void patch on the plane -- so the window
      # looks into the roof space instead of at the tiles a hand's breadth behind it. A void
      # is an index that holds nothing, exactly as a doorway is, so nothing renumbers.
      #
      # ENTIRELY under the dakkapel, never merely mostly: a void cell is a hole in the roof,
      # and a cell half under the box leaves the other half of it open beside a cheek, in
      # front of the glass or above the zinc top, which is half a metre of sky through a
      # roof. Measured over geleen's fifteen dakkapellen, this opens 33 cells where a rule
      # that took any cell whose middle fell under one would open 117.
      #
      # The plane's own frame: `u` runs east from `origin.x`, `v` runs UP THE SLOPE, and a
      # horizontal metre back from the eaves is `slope / run` metres along it. The dormer's
      # foot stands on the plane at its setback and its top meets the plane again where the
      # roof has risen DORMER_HEIGHT, which is `setback + depth` back -- see `dormer`.
      def self.dormer_void(plan, origin_x:, cols:, rows:, width:, height:, run:)
        cw = width / cols
        ch = height / rows
        x1 = plan[:x0] + plan[:width]
        foot = DORMER_SETBACK * height / run
        head = (DORMER_SETBACK + plan[:depth]) * height / run
        columns = (0...cols).select { |c| origin_x + c * cw >= plan[:x0] - 1e-9 && origin_x + (c + 1) * cw <= x1 + 1e-9 }
        lines = (0...rows).select { |r| r * ch >= foot - 1e-9 && (r + 1) * ch <= head + 1e-9 }
        # A dakkapel narrower or shallower than one cell of the roof it sits on covers no
        # whole cell, and opens nothing rather than opening the cell it is inside.
        return nil if columns.empty? || lines.empty?

        Surface::Patch.new(col0: columns.first, row0: lines.first, col1: columns.last, row1: lines.last, material: :void)
      end

      # How many whole rows of a roof plane a dakkapel reaches up from the eaves. Its top
      # meets the roof `DORMER_SETBACK + depth` back horizontally, and a horizontal metre is
      # `slope / run` metres measured up the plane; rounded UP, so the row a panel may start
      # on is clear of the dormer rather than half behind it.
      def self.dormer_rows(plan, run:, slope:, rows:)
        ((DORMER_SETBACK + plan[:depth]) * slope / run / (slope / rows)).ceil
      end

      def self.dormer(row, d, i)
        plan = dormer_plan(row, d)
        return [] unless plan

        run = row.depth / 2.0
        width = plan[:width]
        depth = plan[:depth]
        x0 = plan[:x0]
        x1 = x0 + width
        z_front = row.z0 + DORMER_SETBACK
        y_base = row.eaves + row.rise * DORMER_SETBACK / run
        y_top = y_base + DORMER_HEIGHT
        cols = Walls.cells(width, row.cell)
        rows = [ Walls.cells(DORMER_HEIGHT, row.cell), 1 ].max
        deep = Walls.cells(depth, row.cell)

        # A dakkapel is a WINDOW with a roof over it, and the front carries no patch at all:
        # it had a plaster return in the first and last column, which on every dormer geleen
        # has -- three columns by two rows -- left two glass cells out of six, and 56 of the
        # 86 front cells on the island were wall. Cutting a box into a roof to put a third of
        # a window in it is not worth the roof it costs. The comment that justified the
        # returns -- under three columns there is no middle left to be a window -- is
        # inverted by this: there is no middle because the whole face is the window.
        #
        # fittings: false on all four -- a gutter belongs under the tiles of the main roof,
        # not round a zinc box on the slope, and a downpipe against the house's own wall,
        # not a dormer cheek the width of a door.
        front = Surface.new(kind: :wall, storey: row.storeys, material: Materials.fetch(:glass), origin: Vector3.new(x0, y_base, z_front),
                            u: EAST, v: UP, width: width, height: DORMER_HEIGHT, cols: cols, rows: rows, thickness: Walls::THICKNESS,
                            seed: row.seed + 300 + i, bay: i, fittings: false)
        cheeks = [ x0, x1 ].map do |x|
          Surface.new(kind: :wall, storey: row.storeys, material: Materials.fetch(:plaster), origin: Vector3.new(x, y_base, z_front),
                      u: SOUTH, v: UP, width: depth, height: DORMER_HEIGHT, cols: deep, rows: rows, thickness: Interior::PARTITION_THICKNESS,
                      seed: row.seed + 300 + i, bay: i, fittings: false)
        end
        top = Surface.new(kind: :roof, storey: row.storeys, material: Materials.fetch(:steel), origin: Vector3.new(x0, y_top, z_front),
                          u: EAST, v: SOUTH, width: width, height: depth, cols: cols, rows: deep, thickness: DORMER_TOP_THICKNESS, bay: i, fittings: false)
        [ front, *cheeks, top ]
      end

      # A chimney: a square brick stack on the ridge, standing on the wall at the dwelling's
      # own x1 -- which is where a terrace's flues actually run, and why the stacks of a
      # real row march down the roof a dwelling apart.
      CHIMNEY_SIDE = 0.9
      CHIMNEY_RISE = 1.2
      # A flue is SINGLE-LEAF brick, not the 0.3 m of a cavity wall. At Walls::THICKNESS and
      # running from the eaves, the stack on the worked example weighed 7,192.8 kg -- and
      # under identical damage a flagged dwelling lost all 18 of its ground-floor partition
      # cells to the pancake where its unflagged neighbour lost none. The same trap
      # DORMER_TOP_THICKNESS is calibrated against. At 0.15 m, and started at the roof rather
      # than the eaves, the same stack weighs 1,409.4 kg.
      CHIMNEY_THICKNESS = 0.15

      # 5c. Four walls, or none. The stack stands ON the ridge, so only the corner nearest
      # the ridge is at ridge height and the rest of its foot needs burying: it starts at the
      # roof's own height under the stack's NEAR edge, `ridge - half * rise / run`, which is
      # 0.25 m on the worked example. Running it from the EAVES instead -- as this did --
      # buries 2.5 m of full-thickness brick that does not exist, which is mass on the roof
      # and nothing visible anywhere. One height for all four walls still, so the stack is a
      # box rather than four staircases.
      def self.chimney(row, d, i)
        return [] unless d.chimney && row.roof == "gable" && d.width >= 2 * CHIMNEY_SIDE

        half = CHIMNEY_SIDE / 2.0
        run = row.depth / 2.0
        # The wall at the dwelling's own x1, and NO last case: a party line for every dwelling
        # but the last, and the row's own END WALL for the last -- the wall an end terrace's
        # flue runs in. N dwellings have N-1 party lines, so one stack always has to stand
        # somewhere that is not a party line whatever the rule is, and the end wall is the
        # only other wall there is; a one-dwelling row is that same case rather than a third.
        #
        # The last dwelling used to go half a metre past the party line at x0 instead. On a
        # pair with both flagged that is two 0.9 m stacks 0.95 m apart centre to centre --
        # 50 mm between their brickwork, one fat double stack, on four of geleen's rows --
        # and it was already 0.40 m into its own solar array and 0.09 m into its own dakkapel
        # while it was at it. Here the closest pair measures 5.62 m and both overlaps are nil.
        # Neither widening that offset nor pulling inward from x1 gets away from the array,
        # because the array is CENTRED on the plane: at x0 + half + 1.6 the stack eats 0.90 m
        # of it (and 0.90 m of the dakkapel), pulled in from x1, 0.74-0.81 m. Only a wall at
        # one END of the dwelling is clear of it, and x1 is the end its neighbour is not on.
        cx = d.x1
        cz = (row.z0 + row.z1) / 2.0
        base = row.ridge - half * row.rise / run
        height = row.ridge + CHIMNEY_RISE - base
        rows = [ Walls.cells(height, row.cell), 1 ].max
        corners = [ [ cx - half, cz - half ], [ cx + half, cz - half ], [ cx + half, cz + half ], [ cx - half, cz + half ] ]

        corners.each_with_index.map do |from, e|
          to = corners[(e + 1) % 4]
          along = Vector3.new(to[0] - from[0], 0.0, to[1] - from[1])
          Surface.new(
            kind: :wall, storey: row.storeys, material: Materials.fetch(:brick),
            origin: Vector3.new(from[0], base, from[1]), u: along.normalised, v: UP,
            width: along.length, height: height, cols: Walls.cells(along.length, row.cell), rows: rows,
            thickness: CHIMNEY_THICKNESS, seed: row.seed + 400 + i, bay: i,
            # fittings: false -- a downpipe against a stack 0.9 m square has nowhere to run.
            fittings: false
          )
        end
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
          # An imported ring makes no promise about which way it winds -- Walls.outward
          # works it out per box rather than assuming every ring turns like a hand-laid one.
          out = Walls.outward(box.ring)
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
              # `except` is this box itself: the probe that asks what stands against this
              # wall is a centimetre outside its own skin, and a ring is not behind its own
              # wall. Every OTHER box counts -- `covered_to` only drops a wall an EARLIER
              # box swallows whole, so a later one lapping over part of this edge leaves it
              # standing with its windows looking into that box's brick.
              built << wall(row, from, to, storey: s, openings: openings, edge: box.door && e.zero? ? 0 : 1 + e,
                            bay: box.bay, storeys: box.storeys, storey_height: box.storey_height, seed: row.seed + 100 + i,
                            outward: out, except: box)
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
      # rectangle clipped to its triangle with void, by the same `Roof.clip` a gable end
      # uses: in the plane's own frame the apex sits at (width / 2, height), so the hip is
      # exactly the triangle that method judges against.
      #
      # It is clipped STRICTLY -- no cell kept that sticks out past its hip anywhere across
      # its width -- and the step that leaves is capped, which is what `capped: true` buys.
      # A plane here IS the roof rather than a wall under one, so until the caps could fill
      # a step on a roof this had to keep the old middle rule and stand proud.
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
          # ODD, ALWAYS -- and no longer load-bearing, but it STAYS, because cols is the
          # piece numbering and changing it would renumber every index after it.
          #
          # It was needed while the middle rule clipped these planes: that judged a cell by
          # the line at its column's middle, so the only top-row cell it kept was one whose
          # middle was exactly the apex, and an even column count put the apex on a seam
          # between two columns instead -- which clipped the whole top row of all four
          # planes away and left a square hole where the point should be. Under Roof.clip
          # the apex is drawn either way: an odd count makes the middle column a tent and
          # the client grows two half-width wedges over it, and an even one puts the apex on
          # a seam, where the columns each side reach it with one wedge apiece.
          cols = Walls.cells(along.length, cell)
          cols += 1 if cols.even?
          rows = [ Walls.cells(inward.length, cell), 1 ].max
          Surface.new(kind: :roof, storey: box.storeys, material: Materials.fetch(:roof_tile),
                      origin: Vector3.new(from[0], box.eaves, from[1]), u: along.normalised, v: inward.normalised,
                      width: along.length, height: inward.length, cols: cols, rows: rows, thickness: Roof::THICKNESS,
                      patches: Roof.clip(cols, rows), capped: true, bay: box.bay)
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
