module Game
  module Import
    # Clusters of 3DBAG parts in, row recipes out. Everything the spike's build_world.rb
    # decided, as a class with one job per method: frame a cluster, find its street side,
    # slice the shared depth into dwellings, turn every other part into a box.
    class Rows
      DWELLING_EAVES = 4.0        # a main part lower than this is a shed
      STOREY_TARGET = 2.8
      CELLS = { "house" => 1.0, "shed" => 1.0, "church" => 2.0, "hall" => 2.0, "apartments" => 1.5 }.freeze
      # Categories that are never sliced into dwellings, whatever their parts are tall
      # enough to be: a church and a hall are a row of ZERO dwellings and one bay per part.
      PER_PART = %w[church hall].freeze
      # Which colours a row may be drawn in, by category, drawn by the row's seed. This
      # estate is 1987 brown-and-red brick under anthracite or orange tiles; the church is
      # the church.
      PALETTES = {
        "house" => %w[brown_brick red_brick brown_brick sand_brick dark_brick red_brick],
        "apartments" => %w[brown_brick sand_brick dark_brick],
        "shed" => %w[brown_brick dark_brick],
        "church" => %w[church],
        "hall" => %w[church dark_brick]
      }.freeze
      # A box is a garage when its street-facing edge is at least a car wide.
      GARAGE_WIDTH = 2.5
      # How deep a front garden may be, from the front line to the road's edge. Shallower
      # is a pavement; deeper is not this dwelling's garden.
      GARDEN_MIN = 1.5
      GARDEN_MAX = 25.0

      # A cluster's own axes, not the world's. Named Frame because that is what it is, and
      # deliberately never confused with Terrain::Frame: that one maps survey metres to
      # game metres and is what `@frame` holds, this one maps game metres to one row's
      # local x-along/z-across. Nothing here reaches for the other by a bare constant.
      Frame = Struct.new(:origin, :yaw, keyword_init: true) do
        def u = [ Math.cos(yaw), Math.sin(yaw) ]
        def v = [ -Math.sin(yaw), Math.cos(yaw) ]
        def to_local(gx, gz) = [ (gx - origin[0]) * u[0] + (gz - origin[1]) * u[1], (gx - origin[0]) * v[0] + (gz - origin[1]) * v[1] ]
        def to_world(lx, lz) = [ origin[0] + lx * u[0] + lz * v[0], origin[1] + lx * u[1] + lz * v[1] ]
        def normalised(points)
          locals = points.map { |gx, gz| to_local(gx, gz) }
          Frame.new(origin: to_world(locals.map(&:first).min, locals.map(&:last).min), yaw: yaw)
        end
        def flipped = Frame.new(origin: origin, yaw: yaw + Math::PI)
      end

      def initialize(window:, clusters:, frame:, roads:, categories: nil)
        @parts = window["parts"].to_h { |p| [ p["id"], p ] }
        @clusters = clusters
        @frame = frame
        # A line of one point is not a line: it has no segment to measure against and the
        # client's ribbon has nothing to extrude, so it is dropped here rather than half
        # the way down the pipeline.
        @roads = roads.map { |r| [ Array(r["points"]), (r["width"] || 5.5).to_f ] }.select { |pts, _| pts.length >= 2 }
                      .map { |pts, width| [ pts.map { |x, y| frame.to_game(x, y) }, width ] }
        # Which long side of a row is its street is decided by the roads and nothing else.
        # With none there is no answer to give, and every row would silently take whichever
        # way its annexes happened to lie -- a world of houses facing their own back gardens.
        raise ArgumentError, "a window with no roads cannot say which side of a row is its street" if @roads.empty?

        @categories = categories || {}
      end

      def objects = @clusters.map { |c| build(c) }

      def road_distance(gx, gz)
        nearest_road(gx, gz).fetch(:distance)
      end

      # The nearest road to a point, its width, and the point on it that is nearest.
      def nearest_road(gx, gz)
        best = nil
        @roads.each do |points, width|
          points.each_cons(2) do |(x1, z1), (x2, z2)|
            px, pz = nearest_on_segment(gx, gz, x1, z1, x2, z2)
            distance = Math.hypot(gx - px, gz - pz)
            best = { distance: distance, width: width, point: [ px, pz ] } if best.nil? || distance < best[:distance]
          end
        end
        best
      end

      # The edge of a box that faces the street, or nil: it runs along the row (more x than
      # z), is at least a car wide, and stands no further back than the row's front line.
      # The street is at low z in the row frame. Returns the ring rotated to start at that
      # edge, because the generator puts a box's door on its first edge.
      def self.garage_ring(ring, front_z)
        candidates = ring.each_with_index.filter_map do |a, i|
          b = ring[(i + 1) % ring.length]
          next unless (b[0] - a[0]).abs > (b[1] - a[1]).abs
          next unless Math.hypot(b[0] - a[0], b[1] - a[1]) >= GARAGE_WIDTH
          next unless (a[1] + b[1]) / 2.0 <= front_z + 0.5

          [ (a[1] + b[1]) / 2.0, i ]
        end
        return nil if candidates.empty?

        ring.rotate(candidates.min.last)
      end

      private
        def ring(geojson)
          coords = geojson["type"] == "MultiPolygon" ? geojson["coordinates"].max_by { |poly| area(poly[0]) } : geojson["coordinates"]
          pts = coords[0].map { |x, y| @frame.to_game(x, y) }
          pts.pop if pts.first == pts.last
          pts
        end

        def area(pts) = pts.each_with_index.sum { |(x1, y1), i| x2, y2 = pts[(i + 1) % pts.length]; x1 * y2 - x2 * y1 }.abs / 2.0
        def centroid(pts) = [ pts.sum(&:first) / pts.size, pts.sum(&:last) / pts.size ]
        def bbox(pts) = [ pts.map(&:first).min, pts.map(&:last).min, pts.map(&:first).max, pts.map(&:last).max ]
        def median(values) = values.sort.then { |s| s.size.odd? ? s[s.size / 2] : (s[s.size / 2 - 1] + s[s.size / 2]) / 2.0 }
        def part_height(p) = p["eaves"] && p["ridge"] ? (p["eaves"] + p["ridge"]) / 2.0 : p["h70"]

        def axis_of(env)
          a, b, c = env[0], env[1], env[2]
          e1 = [ b[0] - a[0], b[1] - a[1] ]
          e2 = [ c[0] - b[0], c[1] - b[1] ]
          long = Math.hypot(*e1) >= Math.hypot(*e2) ? e1 : e2
          Math.atan2(long[1], long[0])
        end

        def segment_distance(px, pz, x1, z1, x2, z2)
          dx, dz = x2 - x1, z2 - z1
          l2 = dx * dx + dz * dz
          t = l2.zero? ? 0.0 : (((px - x1) * dx + (pz - z1) * dz) / l2).clamp(0.0, 1.0)
          Math.hypot(px - (x1 + t * dx), pz - (z1 + t * dz))
        end

        def nearest_on_segment(px, pz, x1, z1, x2, z2)
          dx, dz = x2 - x1, z2 - z1
          length2 = dx * dx + dz * dz
          t = length2.zero? ? 0.0 : (((px - x1) * dx + (pz - z1) * dz) / length2).clamp(0.0, 1.0)
          [ x1 + t * dx, z1 + t * dz ]
        end

        def build(c)
          mains = c["main_ids"].map { |id| @parts[id] }
          members = c["pands"].flat_map { |pand| @parts.values.select { |p| p["pand"] == pand } }
          # Judged per main, not over the whole cluster. `mains.all?` demoted five houses of
          # 5.9 to 6.9 m eaves to eight flat boxes because ONE main among them stood at
          # 3.49 m: a main too low to be a dwelling is an outbuilding of the row, not proof
          # that the row is sheds.
          homes = mains.select { |m| (m["eaves"] || m["h70"]) >= DWELLING_EAVES }
          annexes = members - homes
          # The tallest main's category, not the first Pand's. `pands` comes back sorted by
          # id, so a gabled pair whose smaller half classified as a shed was labelled shed
          # by the accident of which of the two ids sorts first. Tallest FIRST rather than
          # tallest full stop: the classifier windows its Pand by centroid and this one
          # windows by geometry, so a cluster can reach in from outside it and the tallest
          # main of all be the one Pand nobody labelled -- which would throw away what its
          # neighbours in the same cluster do say.
          category = mains.sort_by { |m| -part_height(m) }.filter_map { |m| @categories[m["pand"]] }.first ||
                     (homes.any? ? "house" : "shed")
          # Whether this cluster is BUILT as a row of dwellings, which is not the same
          # question as whether its mains are tall enough to be one. A church's nave is a
          # main part well over DWELLING_EAVES, so height alone made Sint-Marcellinus a
          # single 36.5 m "dwelling" under one gable band with nine flat one-storey boxes
          # beside it, every one of them in bay 0 -- and gutting the nave's ground storey
          # then condemned nothing at all, because a church has no bays to condemn.
          houses = homes.any? && !PER_PART.include?(category)
          env = ring(c["envelope"])

          # The row runs along one of the envelope's edge directions; the dwellings'
          # centroids say which of the two.
          yaw = axis_of(env)
          if houses && homes.size >= 2
            cs = homes.map { |m| centroid(ring(m["env"])) }
            along = cs.map { |x, z| x * Math.cos(yaw) + z * Math.sin(yaw) }
            across = cs.map { |x, z| -x * Math.sin(yaw) + z * Math.cos(yaw) }
            yaw += Math::PI / 2 if across.max - across.min > along.max - along.min
          end
          everything = members.flat_map { |p| ring(p["geom"]) } + ring(c["union"])
          frame = Frame.new(origin: env[0], yaw: yaw).normalised(everything)

          # The street side: the nearer road when the two long sides differ by more than
          # three metres, else the side the annexes are not on.
          probe = houses ? homes.flat_map { |m| ring(m["env"]) } : ring(c["union"])
          ux0, uz0, ux1, uz1 = bbox(probe.map { |g| frame.to_local(*g) })
          d_min = road_distance(*frame.to_world((ux0 + ux1) / 2, uz0))
          d_max = road_distance(*frame.to_world((ux0 + ux1) / 2, uz1))
          flip =
            if (d_min - d_max).abs > 3.0
              d_max < d_min
            elsif annexes.any? && houses
              mz = homes.sum { |m| centroid(ring(m["env"]).map { |g| frame.to_local(*g) })[1] } / homes.size
              az = annexes.sum { |p| centroid(ring(p["simple"]).map { |g| frame.to_local(*g) })[1] } / annexes.size
              az < mz
            else
              false
            end
          frame = frame.flipped.normalised(everything) if flip

          local = ->(part, key) { ring(part[key]).map { |g| frame.to_local(*g) } }
          seed = c["pands"].first[-6..].to_i % 1000
          recipe = { "kind" => "row", "category" => category, "pands" => c["pands"].map { |p| p[-6..] },
                     "yaw" => frame.yaw.round(5), "cell" => CELLS.fetch(category, 1.0), "seed" => seed,
                     "dwellings" => [], "boxes" => [] }
          choices = PALETTES.fetch(category, %w[brown_brick])
          recipe["palette"] = choices[seed % choices.length]

          if houses
            boxes = homes.map { |m| [ m, bbox(local.call(m, "env")) ] }.sort_by { |_, b| (b[0] + b[2]) / 2 }
            band_z0 = boxes.map { |_, b| b[1] }.max
            band_z1 = boxes.map { |_, b| b[3] }.min
            if band_z1 - band_z0 < 5.0
              band_z0 = median(boxes.map { |_, b| b[1] })
              band_z1 = median(boxes.map { |_, b| b[3] })
            end
            xs = boxes.map { |_, b| [ b[0], b[2] ] }
            bounds = [ xs.first[0] ] + xs.each_cons(2).map { |a, b| (a[1] + b[0]) / 2.0 } + [ xs.last[1] ]
            recipe["dwellings"] = boxes.each_index.map { |i| { "x0" => bounds[i].round(2), "x1" => bounds[i + 1].round(2) } }
            recipe["band"] = [ band_z0.round(2), band_z1.round(2) ]
            eaves = homes.map { |m| m["eaves"] || m["h70"] * 0.75 }.max
            ridge = median(homes.map { |m| m["ridge"] || m["h70"] * 1.1 })
            storeys = [ (eaves / STOREY_TARGET).round, 1 ].max
            recipe.merge!("eaves" => eaves.round(2), "ridge" => [ ridge, eaves ].max.round(2), "storeys" => storeys,
                          "storey_height" => (eaves / storeys).round(3), "roof" => ridge - eaves > 0.8 ? "gable" : "flat")
            # A main that reaches past the shared band keeps the excess as a full-height box.
            boxes.each_with_index do |(m, _), i|
              [ [ band_z1, 1 ], [ band_z0, -1 ] ].each do |at, side|
                over = Building::RowGenerator.clip(local.call(m, "simple"), 1, at, side)
                next if over.size < 3 || area(over) < 4.0

                recipe["boxes"] << { "ring" => over.map { |x, z| [ x.round(2), z.round(2) ] }, "eaves" => (m["eaves"] || eaves).round(2),
                                     "ridge" => (m["eaves"] || eaves).round(2), "storeys" => storeys, "roof" => "flat", "door" => false, "solid" => false,
                                     "bay" => i, "name" => "#{m['source_id'][-8..]} overflow" }
              end
            end
            annexes.each do |p|
              ring = local.call(p, "simple").map { |x, z| [ x.round(2), z.round(2) ] }
              door = false
              # A one-storey annex whose street edge is a car wide is a garage, and its
              # ring is turned so that edge is the one the generator puts the door on.
              if %w[house apartments].include?(category) && (garage = self.class.garage_ring(ring, band_z0))
                ring = garage
                door = "garage"
              end
              recipe["boxes"] << { "ring" => ring, "eaves" => part_height(p).round(2), "ridge" => part_height(p).round(2), "storeys" => 1,
                                   "roof" => "flat", "door" => door, "solid" => false, "bay" => bay_of(recipe["dwellings"], ring), "name" => p["source_id"][-8..] }
            end
            # A front garden per dwelling that faces a road: the strip from the front line to
            # the road's edge, when the nearest road lies across the front -- in front of the
            # dwelling rather than beside or behind it -- and no box of this bay stands in it.
            recipe["gardens"] = recipe["dwellings"].each_with_index.filter_map do |d, i|
              mx = (d["x0"] + d["x1"]) / 2.0
              road = nearest_road(*frame.to_world(mx, band_z0))
              next unless road

              lx, lz = frame.to_local(*road[:point])
              depth = road[:distance] - road[:width] / 2.0
              next unless lz < band_z0 - 1.0 && (lx - mx).abs < (d["x1"] - d["x0"]) && depth.between?(GARDEN_MIN, GARDEN_MAX)
              next if recipe["boxes"].any? { |b| b["bay"] == i && b["ring"].map(&:last).min < band_z0 - 0.3 }

              { "bay" => i, "depth" => depth.round(2) }
            end
          else
            recipe.merge!("band" => [ 0.0, 0.0 ], "storeys" => [ mains.map { |m| ((m["eaves"] || m["h70"]) / 4.0).round }.max, 1 ].max,
                          "storey_height" => 3.0, "eaves" => mains.map { |m| part_height(m) }.max.round(2), "roof" => "flat")
            recipe["ridge"] = recipe["eaves"]
            # Union rather than concatenation: `annexes` excludes only the mains that became
            # dwellings, so a main too low to be one is in both lists and would otherwise be
            # built twice, in two bays, on the same ground.
            (mains | annexes).sort_by { |p| -p["area"] }.each_with_index do |p, i|
              ring = local.call(p, category == "church" ? "simple" : "env").map { |x, z| [ x.round(2), z.round(2) ] }
              eaves = p["eaves"] || p["h70"] * 0.8
              ridge = p["ridge"] || p["h70"] * 1.1
              roof =
                if category == "church" && p["h70"] / Math.sqrt(p["area"]) > 1.8 && p["area"] < 120
                  "pyramid"
                elsif category == "church" && ridge - eaves > 1.5
                  "gable"
                else
                  "flat"
                end
              storeys = category == "church" ? [ (eaves / 4.0).round, 1 ].max : 1
              recipe["boxes"] << { "ring" => ring, "eaves" => eaves.round(2), "ridge" => [ ridge, eaves ].max.round(2), "storeys" => storeys,
                                   "roof" => roof, "door" => category == "church" && i.zero?, "solid" => category == "shed", "bay" => i, "name" => p["source_id"][-8..] }
            end
            recipe["storeys"] = recipe["boxes"].map { |b| b["storeys"] }.max
          end
          recipe["footprint"] = ring(c["union"]).map { |g| frame.to_local(*g) }.map { |x, z| [ x.round(2), z.round(2) ] }
          # Read back before it leaves: a recipe that Row would refuse -- a roof it has no
          # name for, a box with no bay, dwellings with a gap between them -- is caught here,
          # where the cluster that produced it is still in hand, rather than at fixture load
          # in a suite that cannot say which of a hundred rows was wrong.
          Building::Row.from(recipe)

          radius = everything.map { |g| Math.hypot(*frame.to_local(*g)) }.max + 4.0
          { name: "#{category == 'house' ? 'row' : category}-#{c['cluster']}", x: frame.origin[0].round(3), z: frame.origin[1].round(3),
            yaw: frame.yaw.round(5), radius: radius.round(1), category: category, pands: c["pands"], recipe: recipe }
        end

        # The dwelling a box overlaps most along the row.
        def bay_of(dwellings, ring)
          xs = ring.map(&:first)
          dwellings.each_index.max_by { |i| [ [ dwellings[i]["x1"], xs.max ].min - [ dwellings[i]["x0"], xs.min ].max, 0 ].max } || 0
        end
    end
  end
end
