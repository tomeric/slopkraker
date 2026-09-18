# THROWAWAY. A server to drive the spike worlds on, without touching app code or the dev
# database: run through scripts/serve.sh, which points DATABASE_URL at a SQLite file of
# its own. Loads the spike generator into this process, (re)creates the two spike worlds
# from the recipes beside this script, and starts Puma in-process.
#
#   bin/rails runner docs/superpowers/spikes/2026-09-18-dassenkuillaan/scripts/spike_server.rb
#
# Worlds: /?world=spike-dassenkuil (the estate) and /?world=spike-church (the two churches).
require_relative "geo"
require_relative "terrace"
require "json"

HERE = File.expand_path("..", __dir__)
PORT = (ENV["SPIKE_PORT"] || 3110).to_i

# The app's generator knows nothing about a `spike_row` recipe; this is the same prepend the
# shots test used, registered for reloads too so an edit under app/ does not silently drop it.
module SpikeSurfaces
  def surface_set
    @surface_set ||= recipe["kind"] == "spike_row" ? Spike::Terrace.generate(recipe) : super
  end
end
install = -> { WorldObject.prepend(SpikeSurfaces) unless WorldObject < SpikeSurfaces }
install.call
Rails.application.reloader.to_prepare { install.call }

def load_world!(slug, name, file, srid: nil, origin: [ 0.0, 0.0 ])
  recipes = JSON.parse(File.read(File.join(HERE, file)))
  if (old = World.find_by(slug: slug))
    ObjectDamage.where(world_object_id: old.world_objects.select(:id)).delete_all
    old.matches.destroy_all
    old.destroy!
  end
  world = World.create!(
    slug: slug, name: name, bounds: recipes["bounds"], spawns: recipes["spawns"],
    content_digest: "spike#{Digest::SHA256.hexdigest(File.read(File.join(HERE, file)))[0, 7]}",
    srid: srid, origin_x: origin[0], origin_y: origin[1]
  )
  recipes["statics"].each do |s|
    world.world_objects.create!(
      kind: "static", name: s["name"], x: s["x"], y: s["y"], z: s["z"], yaw: s["yaw"], radius: 0.0,
      cx: (s["x"] / world.chunk_size).floor, cz: (s["z"] / world.chunk_size).floor,
      recipe: { "kind" => s["kind"], "size" => s["size"], "colour" => s["colour"], "friction" => 1.1 }
    )
  end
  recipes["objects"].each do |o|
    world.world_objects.create!(
      kind: "building", name: o["name"], x: o["x"], y: 0.0, z: o["z"], yaw: o["yaw"], radius: o["radius"],
      cx: (o["x"] / world.chunk_size).floor, cz: (o["z"] / world.chunk_size).floor,
      piece_count: o["piece_count"], storey_count: o["storey_count"], recipe: o["recipe"]
    )
  end
  puts "== #{slug}: #{world.summary}"
end

load_world!("spike-dassenkuil", "Dassenkuillaan spike", "recipes-cell-1.0.json", srid: 28_992, origin: [ 185_000.0, 330_000.0 ])
load_world!("spike-church", "Two churches spike", "recipes-church-cell-1.0.json")

require "puma"
require "puma/configuration"
require "puma/launcher"

puts "== spike server: http://localhost:#{PORT}/?world=spike-dassenkuil&vehicle=buggy  (database #{ActiveRecord::Base.connection_db_config.database})"
config = Puma::Configuration.new do |c|
  c.bind "tcp://127.0.0.1:#{PORT}"
  c.app Rails.application
  c.environment Rails.env
  c.threads 0, 5
end
Puma::Launcher.new(config).run
