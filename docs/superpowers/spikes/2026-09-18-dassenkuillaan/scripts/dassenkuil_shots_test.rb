require "application_system_test_case"
require_relative "terrace"

# THROWAWAY. Boots a world built from spike/recipes.json inside the test process -- the
# rows exist only in this transaction and the generator only in this process -- parks the
# car in front of things worth seeing and saves frames. Never part of the suite.
class DassenkuilShotsTest < ApplicationSystemTestCase
  SP = File.expand_path("..", __dir__)
  SHOTS = Rails.root.join("tmp/shots").to_s
  RECIPES = JSON.parse(File.read(File.join(SP, ENV.fetch("RECIPES", "recipes-cell-1.0.json"))))

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
    @match_key = "spike-shots-#{Time.now.to_i}"
    visit_world("spike-dassenkuil", vehicle: ENV.fetch("VEHICLE", "buggy"), quality: ENV.fetch("QUALITY", "low"), match: @match_key)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    wait_for(timeout: 90, message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
    puts "\nbooted in #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)}s"
    sleep 2.0
    unless ENV["KEEP_OVERLAY"]
      press("g")
      press("h")
      sleep 0.6
    end
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


    # Drives a vehicle flat out into the longest ground-storey wall of the first building
    # and reports how many cells of each row it took out: which rows a car can reach.
    def ram_nave
      o = RECIPES["objects"].first
      result = page.evaluate_script(<<~JS, o["name"])
        (() => {
          const id = window.__arenaBuildingIds().find(i => window.__arenaBuildingSpec(i).name === arguments[0])
          const spec = window.__arenaBuildingSpec(id)
          const walls = spec.surfaces.filter(s => s.kind === "wall" && s.storey === 0)
          const wall = walls.slice(0, 40).reduce((a, b) => (b.w > a.w ? b : a))
          const cx = spec.o[0] + wall.o[0] + wall.u[0] * wall.w / 2 + wall.v[0] * wall.h / 2
          const cz = spec.o[2] + wall.o[2] + wall.u[2] * wall.w / 2 + wall.v[2] * wall.h / 2
          window.__ramWall = { id, off: wall.off, cols: wall.cols, rows: wall.rows, h: wall.h, nx: wall.n[0], nz: wall.n[2], cx, cz }
          return window.__ramWall
        })()
      JS
      side = ENV.fetch("SIDE", "-1").to_f
      x = result["cx"] + side * result["nx"] * 22
      z = result["cz"] + side * result["nz"] * 22
      park(x, z, yaw: Math.atan2(-side * result["nx"], -side * result["nz"]))
      page.execute_script("window.__arenaInput = { throttle: 1 }")
      sleep 4.5
      page.execute_script("window.__arenaInput = null")
      sleep 0.8
      rows = page.evaluate_script(<<~JS)
        (() => {
          const w = window.__ramWall
          const rows = []
          for (let r = 0; r < w.rows; r++) { let n = 0; for (let c = 0; c < w.cols; c++) { const st = window.__arenaPieceState(w.off + r * w.cols + c, w.id); if (st && !st.standing && st.material !== "void") n++ } rows.push(n) }
          return { rows, cols: w.cols, cellHeight: +(w.h / w.rows).toFixed(2), car: window.__arenaVehiclePos().map(v => +v.toFixed(1)), wall: [ +w.cx.toFixed(1), +w.cz.toFixed(1) ] }
        })()
      JS
      puts "RAM #{ENV.fetch("VEHICLE", "buggy")}: broken per row (bottom first) #{rows["rows"].inspect} of #{rows["cols"]} cols, cell height #{rows["cellHeight"]} m, car ended at #{rows["car"].inspect}, wall at #{rows["wall"].inspect}"
      shot "30-ram-#{ENV.fetch("VEHICLE", "buggy")}"
    end


    # What a car's hits do to a tall ground storey: rows 0 and 1 of every storey-0 wall of
    # the named building take a driving-speed impact each (30 m/s is about 60 damage),
    # reported through the real path in waves under the batch cap. Then: what broke, and
    # did the server condemn anything.
    def graze_ground_storey
      name = ENV.fetch("TARGET", RECIPES["objects"].first["name"])
      amount = ENV.fetch("AMOUNT", "60").to_f
      rows_hit = ENV.fetch("ROWS", "2").to_i
      page.execute_script(<<~JS, name, amount, rows_hit)
        window.__grazeDone = false
        ;(async () => {
          const id = window.__arenaBuildingIds().find(i => window.__arenaBuildingSpec(i).name === arguments[0])
          const spec = window.__arenaBuildingSpec(id)
          const walls = spec.surfaces.filter(s => s.kind === "wall" && s.storey === 0)
          const cells = []
          for (const s of walls) for (let r = 0; r < Math.min(arguments[2], s.rows); r++) for (let c = 0; c < s.cols; c++) cells.push(s.off + r * s.cols + c)
          window.__grazeBefore = window.__arenaBuildingStanding(id)
          for (let k = 0; k < cells.length; k += 250) {
            for (const i of cells.slice(k, k + 250)) window.__arenaDamagePiece(i, arguments[1], id)
            await new Promise(r => setTimeout(r, 300))
          }
          window.__grazeId = id
          window.__grazeWalls = walls.map(s => ({ off: s.off, cols: s.cols, rows: s.rows }))
          window.__grazeDone = true
        })()
      JS
      wait_for(timeout: 60, message: "grazing never finished") { page.evaluate_script("window.__grazeDone === true") }
      sleep 8
      result = page.evaluate_script(<<~JS)
        (() => {
          const id = window.__grazeId
          const perRow = {}
          let cellsPerRow = {}
          for (const w of window.__grazeWalls) for (let r = 0; r < w.rows; r++) {
            for (let c = 0; c < w.cols; c++) {
              const st = window.__arenaPieceState(w.off + r * w.cols + c, id)
              if (!st || st.material === "void") continue
              cellsPerRow[r] = (cellsPerRow[r] || 0) + 1
              if (!st.standing) perRow[r] = (perRow[r] || 0) + 1
            }
          }
          return { brokenPerRow: perRow, cellsPerRow, before: window.__grazeBefore, after: window.__arenaBuildingStanding(id), collapses: window.__arenaCollapses(), falling: window.__arenaFalling() }
        })()
      JS
      puts "GRAZE #{name} amount #{amount} rows #{rows_hit}: broken per row #{result["brokenPerRow"].inspect} of #{result["cellsPerRow"].inspect}; standing #{result["before"]} -> #{result["after"]}; collapses #{result["collapses"]}, falling #{result["falling"]}"
    end


    # One rocket into the longest ground-storey wall, then: how many cells the client
    # broke against how many the server recorded. A gap is the 512-hits-per-batch cap.
    def rocket_wall
      o = RECIPES["objects"].find { |x| x["name"] == ENV.fetch("TARGET", RECIPES["objects"].first["name"]) }
      wall = page.evaluate_script(<<~JS, o["name"])
        (() => {
          const id = window.__arenaBuildingIds().find(i => window.__arenaBuildingSpec(i).name === arguments[0])
          const spec = window.__arenaBuildingSpec(id)
          const walls = spec.surfaces.filter(s => s.kind === "wall" && s.storey === 0)
          const wall = walls.slice(0, 40).reduce((a, b) => (b.w > a.w ? b : a))
          const cx = spec.o[0] + wall.o[0] + wall.u[0] * wall.w / 2 + wall.v[0] * wall.h / 2
          const cz = spec.o[2] + wall.o[2] + wall.u[2] * wall.w / 2 + wall.v[2] * wall.h / 2
          return { id, cx, cz, nx: wall.n[0], nz: wall.n[2], standing: window.__arenaBuildingStanding(id) }
        })()
      JS
      # A box ring runs either way round, so the wall's normal may point in or out: park on
      # whichever side is outside the footprint.
      yaw = o["yaw"]
      inside = lambda do |wx, wz|
        dx = wx - o["x"]; dz = wz - o["z"]
        lx = dx * Math.cos(yaw) + dz * Math.sin(yaw); lz = -dx * Math.sin(yaw) + dz * Math.cos(yaw)
        ring = o["recipe"]["footprint"]; hit = false
        ring.each_with_index do |(x1, z1), i|
          x2, z2 = ring[(i + 1) % ring.length]
          next unless (z1 > lz) != (z2 > lz)
          hit = !hit if lx < x1 + (lz - z1) / (z2 - z1) * (x2 - x1)
        end
        hit
      end
      side = inside.call(wall["cx"] - wall["nx"] * 14, wall["cz"] - wall["nz"] * 14) ? 1 : -1
      x = wall["cx"] + side * wall["nx"] * 14
      z = wall["cz"] + side * wall["nz"] * 14
      park(x, z, yaw: Math.atan2(-side * wall["nx"], -side * wall["nz"]))
      page.execute_script("window.__arenaInput = { action: true, actionPressed: true }")
      sleep 0.3
      page.execute_script("window.__arenaInput = null")
      sleep 5
      client_broken = wall["standing"] - page.evaluate_script("window.__arenaBuildingStanding(#{wall['id']})")
      Game::Damage::Registry.flush_all!
      row = ObjectDamage.joins(:match).find_by(world_object_id: wall["id"], matches: { key: @match_key })
      puts "ROCKET #{o["name"]}: client broke #{client_broken} cells, server recorded #{row&.broken_count.inspect}, collapsed_from #{row&.collapsed_from.inspect}, collapses seen #{page.evaluate_script('window.__arenaCollapses()')}"
      shot "31-rocket-#{o["name"]}"
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
