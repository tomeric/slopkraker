# THROWAWAY. Turns the exported clusters into spike recipes, generates them, measures the
# budget and writes recipes.json for the shots test. Run with bin/rails runner.
require_relative "geo"
require_relative "terrace"
require "json"

SP = File.expand_path("..", __dir__)
DATA = Spike::Data.new(File.join(SP, "data"))
CELL = (ENV["CELL"] || 1.0).to_f
CENTRE = Spike.to_game(186_330, 332_234)
HALF = 150.0
DWELLING_EAVES = 4.0        # a main part lower than this is a shed, not a house
STOREY_TARGET = 2.8

def centroid(ring)
  [ ring.sum(&:first) / ring.size, ring.sum(&:last) / ring.size ]
end

def bbox(points)
  xs = points.map(&:first)
  zs = points.map(&:last)
  [ xs.min, zs.min, xs.max, zs.max ]
end

def median(values)
  s = values.sort
  s.size.odd? ? s[s.size / 2] : (s[s.size / 2 - 1] + s[s.size / 2]) / 2.0
end

def road_distance(gx, gz)
  DATA.roads.map { |r| Spike.distance_to_polyline(gx, gz, r["line"]) }.min
end

def part_height(part)
  if part["eaves"] && part["ridge"] then (part["eaves"] + part["ridge"]) / 2.0 else part["h70"] end
end

# One cluster -> { name, x, z, yaw, radius, recipe }
def build_cluster(c)
  mains = c["main_ids"].map { |id| DATA.parts[id] }
  members = c["pands"].flat_map { |pand| DATA.parts_of(pand) }
  annex_parts = members - mains
  houses = mains.all? { |m| (m["eaves"] || m["h70"]) >= DWELLING_EAVES }
  env = Spike.ring(c["envelope"])

  # The row runs along one of the envelope's two edge directions -- the edges say the
  # angle, the dwellings' centroids say which of the two they are strung along. Taking the
  # angle from the centroids themselves tilted the frame whenever two neighbours differed
  # in depth.
  yaw = Spike.axis_of(env)
  if houses && mains.size >= 2
    cs = mains.map { |m| centroid(Spike.ring(m["env"])) }
    along = cs.map { |x, z| x * Math.cos(yaw) + z * Math.sin(yaw) }
    across = cs.map { |x, z| -x * Math.sin(yaw) + z * Math.cos(yaw) }
    yaw += Math::PI / 2 if across.max - across.min > along.max - along.min
  end
  everything = members.flat_map { |p| Spike.ring(p["geom"]) } + Spike.ring(c["union"])
  frame = Spike::Frame.new(origin: env[0], yaw: yaw).normalised(everything)

  # Which long side is the street: the nearer road, or failing a clear answer, the side
  # the annexes are not on. Judged from the dwellings' own rectangle, never the union.
  probe = houses ? mains.flat_map { |m| Spike.ring(m["env"]) } : Spike.ring(c["union"])
  ux0, uz0, ux1, uz1 = bbox(probe.map { |g| frame.to_local(*g) })
  d_min = road_distance(*frame.to_world((ux0 + ux1) / 2, uz0))
  d_max = road_distance(*frame.to_world((ux0 + ux1) / 2, uz1))
  flip = if (d_min - d_max).abs > 3.0
    d_max < d_min
  elsif annex_parts.any? && houses
    mz = mains.map { |m| centroid(Spike.ring(m["env"]).map { |g| frame.to_local(*g) })[1] }.sum / mains.size
    az = annex_parts.map { |p| centroid(Spike.ring(p["simple"]).map { |g| frame.to_local(*g) })[1] }.sum / annex_parts.size
    az < mz
  else
    false
  end
  frame = frame.flipped.normalised(everything) if flip

  local_ring = ->(part, key) { Spike.ring(part[key]).map { |g| frame.to_local(*g) } }
  seed = c["pands"].first[-6..].to_i % 1000
  recipe = { "kind" => "spike_row", "yaw" => frame.yaw, "cell" => CELL, "seed" => seed, "dwellings" => [], "annexes" => [] }
  notes = []

  if houses
    boxes = mains.map { |m| [ m, bbox(local_ring.call(m, "env")) ] }.sort_by { |_, b| (b[0] + b[2]) / 2 }
    # The depth every dwelling shares -- the deepest front and the shallowest back -- so a
    # rectangular house is drawn exactly and a deeper neighbour's rear projection becomes
    # a full-height annex. The mean stretched the one and lost the other.
    band_z0 = boxes.map { |_, b| b[1] }.max
    band_z1 = boxes.map { |_, b| b[3] }.min
    if band_z1 - band_z0 < 5.0
      band_z0 = median(boxes.map { |_, b| b[1] })
      band_z1 = median(boxes.map { |_, b| b[3] })
    end
    xs = boxes.map { |_, b| [ b[0], b[2] ] }
    bounds = [ xs.first[0] ] + xs.each_cons(2).map { |a, b| (a[1] + b[0]) / 2.0 } + [ xs.last[1] ]
    recipe["dwellings"] = boxes.each_index.map { |i| { "x0" => bounds[i].round(2), "x1" => bounds[i + 1].round(2), "pand" => boxes[i][0]["pand"][-6..] } }
    recipe["band"] = [ band_z0.round(2), band_z1.round(2) ]
    eaves = mains.map { |m| m["eaves"] || m["h70"] * 0.75 }.max
    ridge = median(mains.map { |m| m["ridge"] || m["h70"] * 1.1 })
    storeys = [ (eaves / STOREY_TARGET).round, 1 ].max
    recipe.merge!("eaves" => eaves.round(2), "ridge" => [ ridge, eaves ].max.round(2), "storeys" => storeys,
                  "storey_height" => (eaves / storeys).round(3), "roof" => ridge - eaves > 0.8 ? "gable" : "flat")
    notes << "snap: band #{boxes.map { |_, b| [ (b[1] - band_z0).round(2), (b[3] - band_z1).round(2) ] }.flatten.map(&:abs).max}m, eaves spread #{(mains.map { |m| m["eaves"] }.compact.max - mains.map { |m| m["eaves"] }.compact.min).round(2)}m, ridge spread #{(mains.map { |m| m["ridge"] }.compact.max - mains.map { |m| m["ridge"] }.compact.min).round(2)}m"

    # A main that reaches past the shared depth band keeps the excess as a full-height
    # annex -- a two-storey rear extension, not a longer terrace.
    boxes.each do |m, _|
      ring = local_ring.call(m, "simple")
      [ [ band_z1, 1 ], [ band_z0, -1 ] ].each do |at, side|
        over = Spike::Terrace.clip(ring, 1, at, side)
        next if over.size < 3 || Spike.shoelace(over) < 4.0

        recipe["annexes"] << { "ring" => over.map { |x, z| [ x.round(2), z.round(2) ] }, "height" => (m["eaves"] || eaves).round(2), "door" => false, "name" => "#{m['source_id'][-8..]} overflow" }
        notes << "overflow #{m['source_id'][-8..]} #{Spike.shoelace(over).round(1)}m2 at #{(m['eaves'] || eaves).round(1)}m"
      end
    end
    annex_parts.each do |p|
      recipe["annexes"] << { "ring" => local_ring.call(p, "simple").map { |x, z| [ x.round(2), z.round(2) ] }, "height" => part_height(p).round(2), "door" => false, "name" => p["source_id"][-8..] }
    end
  else
    # Sheds: every part is a one-storey box with a door; shared walls are generated once.
    recipe["band"] = [ 0.0, 0.0 ]
    recipe["storeys"] = 1
    recipe["storey_height"] = mains.map { |m| part_height(m) }.max.round(2)
    (mains + annex_parts).each do |p|
      b = bbox(local_ring.call(p, "env"))
      recipe["annexes"] << { "ring" => [ [ b[0], b[1] ], [ b[2], b[1] ], [ b[2], b[3] ], [ b[0], b[3] ] ].map { |x, z| [ x.round(2), z.round(2) ] },
                             "height" => part_height(p).round(2), "door" => false, "solid" => true, "name" => p["source_id"][-8..] }
    end
  end
  recipe["footprint"] = Spike.ring(c["union"]).map { |g| frame.to_local(*g) }.map { |x, z| [ x.round(2), z.round(2) ] }
  # What the debug overlay labels a building with: its category and the BAG Pand ids it
  # was built from, shortened to the digits that differ within a neighbourhood.
  recipe["category"] = houses ? "house" : "shed"
  recipe["pands"] = c["pands"].map { |pand| pand[-6..] }

  radius = everything.map { |g| l = frame.to_local(*g); Math.hypot(*l) }.max + 4.0
  { "name" => "#{houses ? 'row' : 'sheds'}-#{c['cluster']}", "x" => frame.origin[0].round(3), "z" => frame.origin[1].round(3), "yaw" => frame.yaw.round(5),
    "radius" => radius.round(1), "houses" => houses, "pands" => c["pands"], "recipe" => recipe, "notes" => notes }
end

def measure(set, object_hash)
  spec = set.to_spec
  cells = 0
  voids = 0
  heaps = 0
  set.surfaces.each do |s|
    s.rows.times do |r|
      s.cols.times do |co|
        m = s.material_at(r, co).name
        if m == :void then voids += 1 else cells += 1 end
        heaps += 1 if s.kind == :rubble && m == :rubble
      end
    end
  end
  fragments = Game::Spec.default_rules.dig(:collapse, :rubble, :fragments)
  { pieces: set.piece_count, surfaces: set.surfaces.size, bytes: JSON.generate(object_hash.merge(spec)).bytesize,
    drawn: cells, voids: voids, heaps: heaps, instances: cells + heaps * fragments }
end

objects = DATA.clusters.map { |c| build_cluster(c) }
totals = Hash.new(0)
puts "%-9s %5s %5s %6s %7s %7s %6s %6s %9s  %s" % %w[name pand dwell storeys pieces bytes drawn heaps instances notes]
objects.each do |o|
  set = Spike::Terrace.generate(o["recipe"])
  o["piece_count"] = set.piece_count
  o["storey_count"] = set.storey_count
  m = measure(set, { "id" => 0, "name" => o["name"], "o" => [ o["x"], 0.0, o["z"] ], "yaw" => o["yaw"] })
  m.each { |k, v| totals[k] += v }
  totals[:dwellings] += o["recipe"]["dwellings"].size
  puts "%-9s %5d %5d %6d %7d %7d %6d %6d %9d  %s" % [ o["name"], o["pands"].size, o["recipe"]["dwellings"].size, set.storey_count, m[:pieces], m[:bytes], m[:drawn], m[:heaps], m[:instances], o["notes"].join("; ") ]
end
puts "TOTAL: #{objects.size} objects, #{totals[:dwellings]} dwellings, #{objects.sum { |o| o['pands'].size }} Pand: #{totals.except(:dwellings).map { |k, v| "#{k} #{v}" }.join(', ')}"

# The street, measured the same way, from the dev database if it is seeded.
if (street = World.find_by(slug: "street"))
  st = Hash.new(0)
  street.world_objects.where(kind: "building").each do |b|
    m = measure(b.surface_set, { "id" => b.id, "name" => b.name, "o" => [ b.x, b.y, b.z ], "yaw" => b.yaw })
    m.each { |k, v| st[k] += v }
  end
  puts "STREET: 12 houses: #{st.map { |k, v| "#{k} #{v}" }.join(', ')}"
end

# Static bodies: a ground slab and the roads as slabs, plus a spawn on Muldershof.
bounds = [ CENTRE[0] - HALF, CENTRE[1] - HALF, CENTRE[0] + HALF, CENTRE[1] + HALF ]
statics = [ { "name" => "ground", "kind" => "ground", "x" => CENTRE[0], "y" => -0.5, "z" => CENTRE[1], "yaw" => 0.0,
              "size" => [ 2 * HALF, 1.0, 2 * HALF ], "colour" => "#4a5159" } ]
DATA.roads.each_with_index do |r, i|
  r["line"].each_cons(2).each_with_index do |((x1, z1), (x2, z2)), j|
    mx = (x1 + x2) / 2
    mz = (z1 + z2) / 2
    next unless mx.between?(bounds[0], bounds[2]) && mz.between?(bounds[1], bounds[3])

    len = Math.hypot(x2 - x1, z2 - z1)
    statics << { "name" => "road-#{i}-#{j}", "kind" => "road", "x" => mx.round(2), "y" => -0.09, "z" => mz.round(2),
                 "yaw" => Math.atan2(x2 - x1, z2 - z1).round(5), "size" => [ r["width"].to_f, 0.2, (len + 0.3).round(2) ], "colour" => "#2e3236" }
  end
end
spawn = { "position" => [ CENTRE[0].round(2), 2.0, CENTRE[1].round(2) ], "yaw" => Math.atan2(0.73, 0.68).round(3) }

File.write(File.join(SP, "recipes-cell-#{CELL}.json"), JSON.pretty_generate(
  "bounds" => bounds, "spawns" => [ spawn ], "statics" => statics, "objects" => objects
))
puts "wrote #{objects.size} objects, #{statics.size} statics -> recipes-cell-#{CELL}.json"
