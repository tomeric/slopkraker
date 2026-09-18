require_relative "geo"
data = Spike::Data.new(ARGV[0])
data.clusters.each do |c|
  env = Spike.ring(c["envelope"])
  yaw = Spike.axis_of(env)
  members = c["pands"].flat_map { |pand| data.parts_of(pand) }
  frame = Spike::Frame.new(origin: env[0], yaw: yaw).normalised(members.flat_map { |p| Spike.ring(p["geom"]) })
  mains = c["main_ids"].map { |id| data.parts[id] }
  puts "cluster #{c['cluster']}: #{c['pands'].size} pand, yaw #{(yaw * 180 / Math::PI).round(1)} deg, origin #{frame.origin.map { |x| x.round(1) }}"
  mains.sort_by { |p| frame.to_local(*Spike.ring(p["env"]).first).first }.each do |p|
    local = Spike.ring(p["env"]).map { |g| frame.to_local(*g) }
    xs = local.map(&:first); zs = local.map(&:last)
    edge_yaw = Spike.axis_of(Spike.ring(p["env"])) - yaw
    puts "  main %s  x %5.1f..%5.1f  z %5.1f..%5.1f  area %5.1f rect %.2f  h70 %.1f eaves %s ridge %s lvls %s  skew %.1f deg" % [
      p["source_id"][-8..], xs.min, xs.max, zs.min, zs.max, p["area"], p["rect"], p["h70"], p["eaves"].inspect, p["ridge"].inspect, p["levels"].inspect,
      ((edge_yaw * 180 / Math::PI) % 90).then { |d| d > 45 ? d - 90 : d } ]
  end
  (members - mains).each do |p|
    local = Spike.ring(p["simple"]).map { |g| frame.to_local(*g) }
    xs = local.map(&:first); zs = local.map(&:last)
    puts "  annex %s x %5.1f..%5.1f  z %5.1f..%5.1f  area %5.1f rect %.2f verts %d  h70 %.1f eaves %s ridge %s  ring %s" % [
      p["source_id"][-8..], xs.min, xs.max, zs.min, zs.max, p["area"], p["rect"], local.size, p["h70"], p["eaves"].inspect, p["ridge"].inspect,
      local.map { |x, z| [ x.round(1), z.round(1) ] }.inspect ]
  end
  # Which long side faces a road: compare the midpoints of z = min and z = max sides.
  ring = Spike.ring(c["union"]).map { |g| frame.to_local(*g) }
  xs = ring.map(&:first); zs = ring.map(&:last)
  front = frame.to_world((xs.min + xs.max) / 2, zs.min)
  back = frame.to_world((xs.min + xs.max) / 2, zs.max)
  df = data.roads.map { |r| Spike.distance_to_polyline(*front, r["line"]) }.min
  db = data.roads.map { |r| Spike.distance_to_polyline(*back, r["line"]) }.min
  puts "  union ring #{ring.size} verts, local box #{xs.min.round(1)}..#{xs.max.round(1)} x #{zs.min.round(1)}..#{zs.max.round(1)}; road: z-min side #{df.round(1)} m, z-max side #{db.round(1)} m"
end
