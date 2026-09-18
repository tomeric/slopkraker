require "application_system_test_case"
require_relative "terrace"

# THROWAWAY. Boots a world built from spike/recipes.json inside the test process -- the
# rows exist only in this transaction and the generator only in this process -- parks the
# car in front of things worth seeing and saves frames. Never part of the suite.
class DassenkuilShotsTest < ApplicationSystemTestCase
  SP = File.expand_path("..", __dir__)
  SHOTS = File.join(SP, "shots")
  RECIPES = JSON.parse(File.read(File.join(SP, "spike", ENV.fetch("RECIPES", "recipes.json"))))

  module SpikeSurfaces
    def surface_set
      @surface_set ||= recipe["kind"] == "spike_row" ? Spike::Terrace.generate(recipe) : super
    end
  end
  WorldObject.prepend(SpikeSurfaces)

  setup do
    world = World.create!(
      slug: "spike-dassenkuil", name: "Dassenkuillaan spike", bounds: RECIPES["bounds"], spawns: RECIPES["spawns"],
      content_digest: "spikedassen1", srid: 28_992, origin_x: 185_000.0, origin_y: 330_000.0
    )
    RECIPES["statics"].each do |s|
      world.world_objects.create!(
        kind: "static", name: s["name"], x: s["x"], y: s["y"], z: s["z"], yaw: s["yaw"], radius: 0.0,
        cx: (s["x"] / world.chunk_size).floor, cz: (s["z"] / world.chunk_size).floor,
        recipe: { "kind" => s["kind"], "size" => s["size"], "colour" => s["colour"], "friction" => 1.1 }
      )
    end
    RECIPES["objects"].each do |o|
      world.world_objects.create!(
        kind: "building", name: o["name"], x: o["x"], y: 0.0, z: o["z"], yaw: o["yaw"], radius: o["radius"],
        cx: (o["x"] / world.chunk_size).floor, cz: (o["z"] / world.chunk_size).floor,
        piece_count: o["piece_count"], storey_count: o["storey_count"], recipe: o["recipe"]
      )
    end
    FileUtils.mkdir_p(SHOTS)
  end

  test "photograph the estate" do
    visit_world("spike-dassenkuil", vehicle: ENV.fetch("VEHICLE", "buggy"), quality: ENV.fetch("QUALITY", "low"), match: "spike-shots-#{Time.now.to_i}")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    wait_for(timeout: 90, message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
    puts "\nbooted in #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)}s"
    sleep 2.0
    press("g")
    press("h")
    sleep 0.6
    puts "draws #{page.evaluate_script('window.__arenaDraws()')}, pieces #{page.evaluate_script('window.__arena.pieces')}, buildings #{page.evaluate_script('window.__arenaBuildingIds().length')}"
    errors = severe_console_errors
    puts "SEVERE console: #{errors.inspect}" if errors.any?

    shots = ENV.fetch("SHOTS_LIST", "row12-street,row12-close,row12-raking,row0-back,row9-end,sheds,row5-front,overview").split(",")
    shots.each { |name| send(name.tr("-", "_")) }
    puts "--- shots in #{SHOTS}"
  end

  private
    def object(name) = RECIPES["objects"].find { |o| o["name"] == name }

    # A point in a row's local frame (x along the row, z across it, the street at z = 0),
    # and the car yaw that looks along local +z (toward the row from the street side).
    def local_to_world(o, lx, lz)
      yaw = o["yaw"]
      [ o["x"] + lx * Math.cos(yaw) - lz * Math.sin(yaw), o["z"] + lx * Math.sin(yaw) + lz * Math.cos(yaw) ]
    end

    def facing(o, direction)
      yaw = o["yaw"]
      dx, dz = case direction
      when :plus_z then [ -Math.sin(yaw), Math.cos(yaw) ]
      when :minus_z then [ Math.sin(yaw), -Math.cos(yaw) ]
      when :plus_x then [ Math.cos(yaw), Math.sin(yaw) ]
      when :minus_x then [ -Math.cos(yaw), -Math.sin(yaw) ]
      end
      Math.atan2(dx, dz)
    end

    def row_mid(o) = (o["recipe"]["dwellings"].first["x0"] + o["recipe"]["dwellings"].last["x1"]) / 2.0

    def park_local(o, lx, lz, direction)
      x, z = local_to_world(o, lx, lz)
      park(x, z, yaw: facing(o, direction))
    end

    def row12_street
      o = object("row-12")
      park_local(o, row_mid(o), -16, :plus_z)
      shot "01-row12-from-the-street"
    end

    def row12_close
      o = object("row-12")
      park_local(o, o["recipe"]["dwellings"][1]["x1"], -7, :plus_z)
      shot "02-row12-close"
    end

    def row12_raking
      o = object("row-12")
      park_local(o, -10, -4, :plus_x)
      shot "03-row12-raking"
    end

    def row0_back
      o = object("row-0")
      park_local(o, row_mid(o), o["recipe"]["band"][1] + 14, :minus_z)
      shot "04-row0-from-the-back"
    end

    def row9_end
      o = object("row-9")
      park_local(o, o["recipe"]["dwellings"].last["x1"] + 14, o["recipe"]["band"].sum / 2.0, :minus_x)
      shot "05-row9-gable-end"
    end

    def sheds
      o = object("sheds-8")
      park_local(o, 3.5, -8, :plus_z)
      shot "06-sheds"
    end

    def row5_front
      o = object("row-5")
      park_local(o, row_mid(o), -12, :plus_z)
      shot "07-row5-front"
    end

    def overview
      o = object("row-12")
      x, z = local_to_world(o, row_mid(o), -30)
      page.execute_script("window.__arenaPlace = { x: #{x}, y: 14.0, z: #{z}, yaw: #{facing(o, :plus_z)} }")
      sleep 0.4
      shot "08-overview-falling-in"
      sleep 1.5
    end


    def door_close
      o = object("row-12")
      park_local(o, (o["recipe"]["dwellings"][1]["x0"] + o["recipe"]["dwellings"][1]["x1"]) / 2.0, -5, :plus_z)
      shot "10-door-close"
    end

    def annex_close
      o = object("row-0")
      a = o["recipe"]["annexes"].max_by { |x| x["ring"].size }
      xs = a["ring"].map(&:first); zs = a["ring"].map(&:last)
      park_local(o, (xs.min + xs.max) / 2.0, zs.max + 6, :minus_z)
      shot "11-annex-close"
    end

    def shed_close
      o = object("sheds-13")
      park_local(o, 2.1, -5, :plus_z)
      shot "12-shed-close"
    end

    def row12_street_near
      o = object("row-12")
      park_local(o, row_mid(o), -10, :plus_z)
      shot "13-row12-from-the-kerb"
    end

    def row9_garage
      o = object("row-9")
      park_local(o, o["recipe"]["dwellings"].last["x1"] + 2, -9, :plus_z)
      shot "14-row9-end-and-garage"
    end


    def row18_front
      o = object("row-18")
      park_local(o, row_mid(o), -11, :plus_z)
      shot "15-row18-front"
    end

    def row5_kerb
      o = object("row-5")
      park_local(o, o["recipe"]["dwellings"].first["x0"] - 4, -9, :plus_z)
      shot "16-row5-three-quarter"
    end

    def sheds_fixed
      o = object("sheds-13")
      park_local(o, 2.1, -6, :plus_z)
      shot "17-sheds-solid"
      o = object("sheds-8")
      park_local(o, 3.6, -6, :plus_z)
      shot "18-sheds-three"
    end

    def kerb_raking
      o = object("row-12")
      park_local(o, -6, -9, :plus_x)
      shot "19-row12-raking-from-the-kerb"
    end

    def churches
      RECIPES["objects"].each do |o|
        ring = o["recipe"]["footprint"]
        xs = ring.map(&:first); zs = ring.map(&:last)
        mid_x = (xs.min + xs.max) / 2.0; mid_z = (zs.min + zs.max) / 2.0
        tag = o["name"][-6..]
        park_local(o, mid_x, zs.min - 40, :plus_z)
        shot "20-church-#{tag}-front"
        park_local(o, xs.min - 35, mid_z, :plus_x)
        shot "21-church-#{tag}-side"
        park_local(o, mid_x, zs.min - 14, :plus_z)
        shot "22-church-#{tag}-close"
        x, z = local_to_world(o, mid_x + 30, zs.min - 55)
        page.execute_script("window.__arenaPlace = { x: #{x}, y: 22.0, z: #{z}, yaw: #{facing(o, :plus_z) - 0.45} }")
        sleep 0.5
        shot "23-church-#{tag}-high"
        sleep 1.5
      end
    end


    def row5_again
      o = object("row-5")
      park_local(o, row_mid(o), -7, :plus_z)
      shot "24-row5-front"
      park_local(o, o["recipe"]["dwellings"].first["x0"] - 2, -6.5, :plus_z)
      shot "25-row5-three-quarter"
      park_local(o, row_mid(o), o["recipe"]["band"][1] + 12, :minus_z)
      shot "26-row5-back"
    end

    def press(key)
      page.driver.browser.action.key_down(key).key_up(key).perform
      sleep 0.3
    end

    def park(x, z, yaw: 0)
      page.execute_script("window.__arenaPlace = { x: #{x}, y: 2.0, z: #{z}, yaw: #{yaw} }")
      sleep ENV.fetch("SETTLE", "1.5").to_f
    end

    def shot(name)
      page.save_screenshot(File.join(SHOTS, "#{name}.png"))
    end
end
