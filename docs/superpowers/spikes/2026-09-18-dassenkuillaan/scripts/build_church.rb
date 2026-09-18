# THROWAWAY. A church as the parts 3DBAG already split it into: every part a box with its
# own eaves and ridge, roofed by its shape -- pyramid on a tower, gable on a nave or a
# chapel, flat on a shed. Nothing knows it is a church except the classifier.
require_relative "geo"
require_relative "terrace"
require "json"

SP = File.expand_path("..", __dir__)
CELL = (ENV["CELL"] || 1.0).to_f
parts = JSON.parse(File.read(File.join(SP, "data", "churches.json")))
churches = parts.group_by { |p| p["pand"] }

def bbox(points)
  xs = points.map(&:first)
  zs = points.map(&:last)
  [ xs.min, zs.min, xs.max, zs.max ]
end

objects = []
churches.each_with_index do |(pand, ps), n|
  ps = ps.reject { |p| p["area"] < 4.0 }                       # a spire tip of one square metre draws as a stick
  nave = ps.max_by { |p| p["area"] }
  yaw = Spike.axis_of(Spike.ring(nave["env"]))
  everything = ps.flat_map { |p| Spike.ring(p["geom"]) }
  frame = Spike::Frame.new(origin: Spike.ring(nave["env"])[0], yaw: yaw).normalised(everything)
  boxes = ps.sort_by { |p| -p["area"] }.map do |p|
    ring = Spike.ring(p["simple"]).map { |g| frame.to_local(*g) }
    eaves = p["eaves"] || p["h70"] * 0.8
    ridge = p["ridge"] || p["h70"] * 1.1
    slender = p["h70"] / Math.sqrt(p["area"])
    roof = if slender > 1.8 && p["area"] < 120 then "pyramid"
    elsif ridge - eaves > 1.5 then "gable"
    else "flat"
    end
    storeys = [ (eaves / 4.0).round, 1 ].max
    { "ring" => ring.map { |x, z| [ x.round(2), z.round(2) ] }, "eaves" => eaves.round(2), "ridge" => ridge.round(2),
      "storeys" => storeys, "roof" => roof, "door" => p.equal?(nave), "name" => p["source_id"][-8..],
      "solid" => false }
  end
  # The rubble footprint: the nave's ring stands in for a union.
  footprint = Spike.ring(nave["simple"]).map { |g| frame.to_local(*g) }.map { |x, z| [ x.round(2), z.round(2) ] }
  recipe = { "kind" => "spike_row", "yaw" => frame.yaw, "cell" => CELL, "seed" => pand[-6..].to_i % 1000,
             "band" => [ 0.0, 0.0 ], "storeys" => boxes.map { |b| b["storeys"] }.max, "storey_height" => 4.0,
             "dwellings" => [], "annexes" => boxes, "footprint" => footprint,
             "category" => "church", "pands" => [ pand[-6..] ] }
  set = Spike::Terrace.generate(recipe)
  spec = set.to_spec
  radius = everything.map { |g| Math.hypot(*frame.to_local(*g)) }.max + 4.0
  # Placed in its own world, side by side: 120 m apart on x.
  x = n * 120.0
  objects << { "name" => "church-#{pand[-6..]}", "x" => x, "z" => 0.0, "yaw" => frame.yaw.round(5), "radius" => radius.round(1),
               "piece_count" => set.piece_count, "storey_count" => set.storey_count, "recipe" => recipe, "pands" => [ pand ], "houses" => false,
               "frame_origin" => frame.origin }
  puts "#{pand}: #{boxes.size} parts -> #{set.surfaces.size} surfaces, #{set.piece_count} pieces, #{JSON.generate(spec).bytesize} bytes"
  boxes.each { |b| puts "   %-10s %-7s storeys %d eaves %5.1f ridge %5.1f ring %2d verts" % [ b["name"], b["roof"], b["storeys"], b["eaves"], b["ridge"], b["ring"].size ] }
end

statics = [ { "name" => "ground", "kind" => "ground", "x" => 60.0, "y" => -0.5, "z" => 0.0, "yaw" => 0.0, "size" => [ 400.0, 1.0, 400.0 ], "colour" => "#4a5159" } ]
File.write(File.join(SP, "recipes-church-cell-#{CELL}.json"), JSON.pretty_generate(
  "bounds" => [ -140, -200, 260, 200 ], "spawns" => [ { "position" => [ 0.0, 2.0, -60.0 ], "yaw" => 0.0 } ], "statics" => statics, "objects" => objects
))
puts "wrote recipes-church-cell-#{CELL}.json"
