# THROWAWAY spike generator. A cluster of attached dwellings -- a terrace row, a
# semi-detached pair, a lone house, or a huddle of sheds -- generated as ONE building.
#
# Everything is built in a row-aligned local frame (x along the row, z across it, the
# street at z = 0) with the existing Walls / Openings / Interior / Roof / Rubble modules,
# then every surface is rotated by the row's yaw so the client needs no change.
#
# The recipe (string keys, JSON-safe):
#   kind "spike_row", yaw, cell, seed,
#   band [z0, z1]            the dwellings' shared depth
#   storeys, storey_height, eaves, ridge, roof ("gable" | "flat")
#   dwellings [ { "x0", "x1" } ... ]                  sorted along x, sharing party walls
#   annexes   [ { "ring" [[x, z] ...], "height", "door" } ... ]   one-storey flat-roofed boxes
#   footprint [[x, z] ...]   the union ring, for the wreckage
#
# THE ORDER IS THE CONTRACT (as in Generator): dwelling walls, end walls, party walls,
# interiors, roof, annexes, rubble last.
module Spike
  module Terrace
    EAST = Game::Vector3.new(1, 0, 0)
    SOUTH = Game::Vector3.new(0, 0, 1)
    UP = Game::Vector3.new(0, 1, 0)
    TOLERANCE = 0.5

    # What Walls.wall reads off a recipe.
    Local = Struct.new(:storeys, :storey_height, :cell, :seed, keyword_init: true)

    def self.generate(recipe)
      r = recipe.transform_keys(&:to_s)
      cell = r.fetch("cell", 1.0).to_f
      seed = r.fetch("seed", 0).to_i
      band_z0, band_z1 = r.fetch("band")
      dwellings = r.fetch("dwellings", [])
      annexes = r.fetch("annexes", [])
      storeys = r.fetch("storeys", 1).to_i
      storey_height = r.fetch("storey_height", 2.8).to_f
      local = Local.new(storeys: storeys, storey_height: storey_height, cell: cell, seed: seed)
      built = []
      row_rect = nil

      if dwellings.any?
        row_x0 = dwellings.first["x0"].to_f
        row_x1 = dwellings.last["x1"].to_f
        row_rect = [ row_x0, band_z0, row_x1, band_z1 ]

        # 1. Front and back wall of every dwelling, storey by storey. The front gets the door.
        dwellings.each_with_index do |d, i|
          openings = Game::Building::Openings.new(seed: seed + i)
          x0 = d["x0"].to_f
          x1 = d["x1"].to_f
          storeys.times do |storey|
            built << wall(local, [ x0, band_z0 ], [ x1, band_z0 ], storey: storey, openings: openings, edge: 0)
          end
          storeys.times do |storey|
            built << wall(local, [ x1, band_z1 ], [ x0, band_z1 ], storey: storey, openings: openings, edge: 2)
          end
        end

        # 2. The two end walls of the row.
        storeys.times { |s| built << wall(local, [ row_x1, band_z0 ], [ row_x1, band_z1 ], storey: s, openings: Game::Building::Openings.new(seed: seed + 7), edge: 1) }
        storeys.times { |s| built << wall(local, [ row_x0, band_z1 ], [ row_x0, band_z0 ], storey: s, openings: Game::Building::Openings.new(seed: seed + 11), edge: 3) }

        # 3. Party walls: one between each pair of neighbours, solid brick, no openings.
        dwellings.each_cons(2) do |a, b|
          x = (a["x1"].to_f + b["x0"].to_f) / 2.0
          storeys.times { |s| built << wall(local, [ x, band_z0 ], [ x, band_z1 ], storey: s, openings: nil, edge: 5) }
        end

        # 4. Each dwelling's decks and partition.
        dwellings.each do |d|
          built.concat Game::Building::Interior.build(dwelling_recipe(r, d, band_z0, band_z1))
        end

        # 5. One roof over the whole row: two planes and two gable ends, or one flat deck.
        built.concat Game::Building::Roof.build(row_recipe(r, row_x0, row_x1, band_z0, band_z1))
      end

      # 6. Boxes: annexes, sheds, and the parts of a multi-part building. Each is a ring
      #    with its own eaves, ridge, storeys and roof. Walls are generated once each --
      #    never where a box stands against the row or inside a bigger box, never twice
      #    where two boxes meet.
      kept_edges = []
      containers = []
      annexes.each_with_index do |annex, i|
        ring = annex.fetch("ring").map { |x, z| [ x.to_f, z.to_f ] }
        eaves = (annex["eaves"] || annex.fetch("height")).to_f
        ridge = (annex["ridge"] || eaves).to_f
        box_storeys = annex.fetch("storeys", 1).to_i
        box = Local.new(storeys: box_storeys, storey_height: eaves / box_storeys, cell: cell, seed: seed + 100 + i)
        openings = annex["solid"] ? nil : Game::Building::Openings.new(seed: seed + 100 + i)
        edges(ring).each_with_index do |(from, to), e|
          next if row_rect && on_or_inside?(from, row_rect) && on_or_inside?(to, row_rect)
          next if containers.any? { |c| inside_ring?(from, c) && inside_ring?(to, c) }
          next if kept_edges.any? { |k| coincident?(k, [ from, to ]) }

          kept_edges << [ from, to ]
          box_storeys.times do |storey|
            built << wall(box, from, to, storey: storey, openings: openings, edge: (annex["door"] && e.zero?) ? 0 : 1 + e)
          end
        end
        box_storeys.times do |storey|
          built << clipped_deck(ring, row_rect, containers, y: storey * box.storey_height, cell: cell, kind: :floor,
                                material: storey.zero? ? :concrete : :timber, storey: storey,
                                thickness: Game::Building::Interior::DECK_THICKNESS)
        end
        case annex.fetch("roof", "flat")
        when "gable"
          built.concat Game::Building::Roof.gable(box_recipe(ring, box_storeys, eaves, ridge, cell, seed))
        when "pyramid"
          built.concat pyramid(ring, box_storeys, eaves, ridge, cell)
        else
          built << clipped_deck(ring, row_rect, containers, y: eaves, cell: cell, kind: :roof, material: :concrete,
                                storey: box_storeys, thickness: Game::Building::Roof::THICKNESS)
        end
        containers << ring unless annex["thin"]
      end

      # 7. Rubble, LAST, over the union footprint.
      rubble = Game::Building::Rubble.build(union_recipe(r), built)
      surfaces = (built + rubble).map { |s| rotate(s, r.fetch("yaw", 0.0).to_f) }
      Game::Building::SurfaceSet.new(surfaces, storey_count: storeys)
    end

    def self.wall(local, from, to, storey:, openings:, edge:)
      along = Game::Vector3.new(to[0] - from[0], 0.0, to[1] - from[1])
      length = along.length
      cols = Game::Building::Walls.cells(length, local.cell)
      rows = Game::Building::Walls.cells(local.storey_height, local.cell)
      patches = openings ? openings.for_wall(edge: edge, storey: storey, cols: cols, rows: rows) : []

      Game::Building::Surface.new(
        kind: :wall, storey: storey, material: Game::Materials.fetch(:brick),
        origin: Game::Vector3.new(from[0], storey * local.storey_height, from[1]),
        u: along.normalised, v: UP, width: length, height: local.storey_height,
        cols: cols, rows: rows, thickness: Game::Building::Walls::THICKNESS,
        patches: patches, seed: local.seed
      )
    end

    def self.dwelling_recipe(r, d, z0, z1)
      x0 = d["x0"].to_f
      x1 = d["x1"].to_f
      Game::Building::Recipe.from(
        footprint: [ [ x0, z0 ], [ x1, z0 ], [ x1, z1 ], [ x0, z1 ] ],
        storeys: r["storeys"], storey_height: r["storey_height"], eaves: r["eaves"], ridge: r["ridge"],
        roof: r["roof"], cell: r["cell"], seed: r["seed"]
      )
    end

    def self.row_recipe(r, x0, x1, z0, z1)
      Game::Building::Recipe.from(
        footprint: [ [ x0, z0 ], [ x1, z0 ], [ x1, z1 ], [ x0, z1 ] ],
        storeys: r["storeys"], storey_height: r["storey_height"], eaves: r["eaves"], ridge: r["ridge"],
        roof: r["roof"], cell: r["cell"], seed: r["seed"]
      )
    end

    def self.union_recipe(r)
      Game::Building::Recipe.from(
        footprint: r.fetch("footprint"), storeys: [ r.fetch("storeys", 1), 1 ].max,
        storey_height: r.fetch("storey_height", 2.8), eaves: r.fetch("eaves", 2.8), ridge: r.fetch("ridge", r.fetch("eaves", 2.8)),
        roof: "flat", cell: r.fetch("cell", 1.0), seed: r.fetch("seed", 0)
      )
    end

    # A horizontal grid over the ring's bounding box, void wherever a cell's centre falls
    # outside the ring or inside the row -- geometry culled, index space kept.
    def self.clipped_deck(ring, row_rect, containers = [], y:, cell:, kind:, material:, storey:, thickness:)
      xs = ring.map(&:first)
      zs = ring.map(&:last)
      x0, x1, z0, z1 = xs.min, xs.max, zs.min, zs.max
      cols = Game::Building::Walls.cells(x1 - x0, cell)
      rows = Game::Building::Walls.cells(z1 - z0, cell)
      cw = (x1 - x0) / cols
      ch = (z1 - z0) / rows
      # Void cells are merged into runs along each row: one patch per run rather than one
      # per cell, which is most of the difference in spec bytes between a clipped deck
      # and a plain one.
      patches = rows.times.flat_map do |row|
        void = cols.times.reject do |col|
          cx = x0 + (col + 0.5) * cw
          cz = z0 + (row + 0.5) * ch
          Game::Building::Rubble.contains?(ring, cx, cz) &&
            !(row_rect && strictly_inside?([ cx, cz ], row_rect)) &&
            containers.none? { |c| Game::Building::Rubble.contains?(c, cx, cz) }
        end
        void.slice_when { |a, b| b != a + 1 }.map do |run|
          Game::Building::Surface::Patch.new(col0: run.first, row0: row, col1: run.last, row1: row, material: :void)
        end
      end

      Game::Building::Surface.new(
        kind: kind, storey: storey, material: Game::Materials.fetch(material),
        origin: Game::Vector3.new(x0, y, z0), u: EAST, v: SOUTH,
        width: x1 - x0, height: z1 - z0, cols: cols, rows: rows, thickness: thickness, patches: patches
      )
    end

    def self.box_recipe(ring, storeys, eaves, ridge, cell, seed)
      xs = ring.map(&:first)
      zs = ring.map(&:last)
      Game::Building::Recipe.from(
        footprint: [ [ xs.min, zs.min ], [ xs.max, zs.min ], [ xs.max, zs.max ], [ xs.min, zs.max ] ],
        storeys: storeys, storey_height: eaves / storeys, eaves: eaves, ridge: [ ridge, eaves ].max,
        roof: "gable", cell: cell, seed: seed
      )
    end

    # Four triangular planes from the eaves of the ring's box up to one apex: a spire, a
    # hip on a square tower. Each plane is a rectangle grid clipped to its triangle with
    # void, exactly as a gable end is -- Roof.clip already draws that triangle.
    def self.pyramid(ring, storeys, eaves, ridge, cell)
      xs = ring.map(&:first)
      zs = ring.map(&:last)
      x0, x1, z0, z1 = xs.min, xs.max, zs.min, zs.max
      cx = (x0 + x1) / 2.0
      cz = (z0 + z1) / 2.0
      rise = [ ridge - eaves, 0.5 ].max
      corners = [ [ x0, z0 ], [ x1, z0 ], [ x1, z1 ], [ x0, z1 ] ]
      corners.each_with_index.map do |from, i|
        to = corners[(i + 1) % 4]
        along = Game::Vector3.new(to[0] - from[0], 0.0, to[1] - from[1])
        mid = [ (from[0] + to[0]) / 2.0, (from[1] + to[1]) / 2.0 ]
        inward = Game::Vector3.new(cx - mid[0], rise, cz - mid[1])
        span = along.length
        slope = inward.length
        cols = Game::Building::Walls.cells(span, cell)
        rows = [ Game::Building::Walls.cells(slope, cell), 1 ].max
        Game::Building::Surface.new(
          kind: :roof, storey: storeys, material: Game::Materials.fetch(:roof_tile),
          origin: Game::Vector3.new(from[0], eaves, from[1]),
          u: along.normalised, v: inward.normalised,
          width: span, height: slope, cols: cols, rows: rows,
          thickness: Game::Building::Roof::THICKNESS,
          patches: Game::Building::Roof.clip(cols, rows)
        )
      end
    end

    def self.inside_ring?(p, ring, tol = TOLERANCE)
      Game::Building::Rubble.contains?(ring, p[0], p[1]) || Game::Building::Rubble.distance_to_ring(ring, p[0], p[1]) <= tol
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

    # Two segments lie along the same line and overlap: the second is a wall that exists.
    def self.coincident?(a, b, tol = 0.4)
      (a0, a1), (b0, b1) = a, b
      da = [ a1[0] - a0[0], a1[1] - a0[1] ]
      la = Math.hypot(*da)
      return false if la < 1e-6

      dir = [ da[0] / la, da[1] / la ]
      # Both of b's endpoints within `tol` of a's line...
      [ b0, b1 ].each do |p|
        off = (p[0] - a0[0]) * -dir[1] + (p[1] - a0[1]) * dir[0]
        return false if off.abs > tol
      end
      # ...and overlapping along it.
      t0 = (b0[0] - a0[0]) * dir[0] + (b0[1] - a0[1]) * dir[1]
      t1 = (b1[0] - a0[0]) * dir[0] + (b1[1] - a0[1]) * dir[1]
      [ t0, t1 ].max > tol && [ t0, t1 ].min < la - tol
    end

    # Local -> world: x along the row, z across it, y untouched. The same handedness as
    # (EAST, SOUTH), so every normal comes out the way the generator meant it.
    def self.rotate(surface, yaw)
      c = Math.cos(yaw)
      s = Math.sin(yaw)
      rot = ->(v) { Game::Vector3.new(v.x * c - v.z * s, v.y, v.x * s + v.z * c) }
      Game::Building::Surface.new(
        kind: surface.kind, storey: surface.storey, material: surface.material,
        origin: rot.call(surface.origin), u: rot.call(surface.u), v: rot.call(surface.v),
        width: surface.width, height: surface.height, cols: surface.cols, rows: surface.rows,
        thickness: surface.thickness, patches: surface.patches, seed: surface.seed, mix: surface.mix
      )
    end

    # Sutherland-Hodgman against one half-plane: keeps the part of `ring` where
    # `axis` (0 for x, 1 for z) is >= `at` (side +1) or <= `at` (side -1).
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
  end
end
