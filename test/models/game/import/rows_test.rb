require "test_helper"

class Game::Import::RowsTest < ActiveSupport::TestCase
  def files = Rails.root.join("test/fixtures/files/geleen")
  def rows
    @rows ||= Game::Import::Rows.new(
      window: JSON.parse(files.join("window.json").read), clusters: JSON.parse(files.join("rows.json").read),
      frame: Game::Terrain::Frame.mijnstreek, roads: JSON.parse(files.join("roads.json").read)
    )
  end

  # The OTHER island, exported by the same four queries at the same parameters the rake task
  # uses (`cx=187006 cy=331447 radius=60`). The estate window has no church in it, no cluster
  # whose mains differ about being dwellings, and no cluster whose Pand disagree about what
  # they are -- so every judgement this file makes about those three things had nothing to be
  # made against until this window was checked in beside it. Its categories are passed as the
  # task passes them, because the church path is chosen by category and by nothing else.
  def church_files = files.join("church")
  def church_rows
    @church_rows ||= Game::Import::Rows.new(
      window: JSON.parse(church_files.join("window.json").read), clusters: JSON.parse(church_files.join("rows.json").read),
      frame: Game::Terrain::Frame.mijnstreek, roads: JSON.parse(church_files.join("roads.json").read),
      categories: JSON.parse(church_files.join("features.json").read).to_h { |f| [ f["pand"], Game::Import::Classifier.category(f).to_s ] }
    )
  end

  test "the window clusters into fourteen dwelling rows and sixteen shed huddles" do
    objects = rows.objects
    houses = objects.select { |o| o[:category] == "house" }
    assert_equal 30, objects.length
    assert_equal 14, houses.length
    assert_equal [ 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 4, 4 ], houses.map { |o| o[:recipe]["dwellings"].length }.sort
  end

  test "every recipe generates, carries its bays, and lands where the frame says" do
    rows.objects.each do |o|
      set = Game::Building::Generator.call(o[:recipe])
      assert_operator set.piece_count, :>, 0, o[:name]
      assert_equal o[:recipe]["dwellings"].length.clamp(1, 99), set.bays.length if o[:recipe]["dwellings"].any?
      assert_operator o[:radius], :<, 125, "#{o[:name]} would not fit a chunk"
    end
    centre = rows.objects.sum { |o| o[:x] } / 30.0
    assert_in_delta 1330.0, centre, 40.0, "the estate sits where Dassenkuillaan is in the mijnstreek frame"
  end

  # Sint-Marcellinus. Judged on the heights of its mains alone the church passed for a
  # terrace: its nave is one main part of 36.5 m well over DWELLING_EAVES, so it came out as
  # a single "dwelling" under one gable band with nine flat one-storey boxes beside it and
  # every one of them in bay 0 -- and a building with one bay cannot lose a bay, so gutting
  # the nave's ground storey condemned nothing at all.
  test "the church is a row of no dwellings and one bay per part" do
    church = church_rows.objects.find { |o| o[:category] == "church" }
    assert church, "no church on the church island"
    boxes = church[:recipe]["boxes"]

    assert_equal [], church[:recipe]["dwellings"], "the nave is a part of a church, not a dwelling"
    assert_operator boxes.length, :>=, 6, "the church came in as fewer parts than it has"
    assert_equal (0...boxes.length).to_a, boxes.map { |b| b["bay"] }.sort, "every part is a bay of its own"
    assert_includes boxes.map { |b| b["roof"] }, "pyramid", "nothing on the church is slender enough to be a tower"
    assert_includes boxes.map { |b| b["roof"] }, "gable", "the nave is flat-roofed"
    assert_equal 1, boxes.count { |b| b["door"] }, "the door goes on the largest part and on nothing else"
    assert boxes.first["door"], "the parts are sorted largest first, so the door is on the first of them"
  end

  test "every recipe on the church island generates, and a row of boxes is one bay per box" do
    church_rows.objects.each do |o|
      set = Game::Building::Generator.call(o[:recipe])
      assert_operator set.piece_count, :>, 0, o[:name]
      assert_operator o[:radius], :<, 125, "#{o[:name]} would not fit a chunk"
      next if o[:recipe]["dwellings"].any?

      assert_equal o[:recipe]["boxes"].each_index.to_a, set.bays, "#{o[:name]}: a box with no bay of its own"
    end
  end

  # Judged over the cluster rather than per main, ONE low part condemned the lot: these five
  # Pand are houses of 5.9 to 6.9 m eaves and came out as eight flat boxes because one main
  # among them stands at 3.49 m.
  test "a main too low to be a dwelling becomes a box of the row rather than demoting it" do
    row = church_rows.objects.find { |o| o[:recipe]["pands"].include?("046662") }
    assert row, "the five-Pand cluster is not in the window"

    assert_equal 4, row[:recipe]["dwellings"].length, "the four mains over 4 m are dwellings"
    assert_includes row[:recipe]["boxes"].map { |b| b["name"] }, "045650/1", "the 3.49 m main is a box beside them"
  end

  # Two Pand: a 3.08 m outbuilding whose id sorts first, and the gabled house it belongs to.
  # The category used to come from the first Pand, so the pair was labelled `shed` -- which
  # picks the cell size, the name and, now, whether the cluster is built per part at all.
  test "a row's category is its tallest main's, not its first Pand's" do
    pair = church_rows.objects.find { |o| o[:recipe]["pands"] == %w[121244 121245] }
    assert pair, "the two-Pand cluster is not in the window"

    assert_equal "house", pair[:category]
    assert_equal 1, pair[:recipe]["dwellings"].length
    assert_equal 1, pair[:recipe]["boxes"].length, "the low main stands beside the house as a box"
  end

  test "a row's street side faces its nearest road" do
    row12 = rows.objects.find { |o| o[:recipe]["pands"].include?("053076") }
    x, z = row12[:x], row12[:z]
    yaw = row12[:yaw]
    mid = (row12[:recipe]["dwellings"].first["x0"] + row12[:recipe]["dwellings"].last["x1"]) / 2.0
    front = [ x + mid * Math.cos(yaw) - (-6) * Math.sin(yaw), z + mid * Math.sin(yaw) + (-6) * Math.cos(yaw) ]
    back = [ x + mid * Math.cos(yaw) - 15 * Math.sin(yaw), z + mid * Math.sin(yaw) + 15 * Math.cos(yaw) ]
    assert_operator rows.road_distance(*front), :<, rows.road_distance(*back)
  end

  test "every row carries a palette the table knows, and the estate is not one colour" do
    palettes = rows.objects.map { |o| o[:recipe]["palette"] }

    palettes.each { |key| assert Game::Palettes.key?(key), "#{key} is not a palette" }
    assert_operator palettes.uniq.length, :>, 1, "thirty rows in one colour is the estate we had"
    church = church_rows.objects.find { |o| o[:category] == "church" }
    assert_equal "church", church[:recipe]["palette"]
  end

  # Pure geometry, so it can be asked of rings that exist and rings that do not. The
  # street is at low z in the row frame; `front_z` is the row's front line.
  test "a street-facing box a car wide is a garage, and its street edge comes first" do
    garage = Game::Import::Rows.garage_ring([ [ 0, 3 ], [ 0, 0 ], [ 6, 0 ], [ 6, 3 ] ], 0.0)
    assert_equal [ [ 0, 0 ], [ 6, 0 ], [ 6, 3 ], [ 0, 3 ] ], garage, "rotated so the edge along the street is first"
    assert_equal [ [ 0, 0 ], [ 6, 0 ], [ 6, 3 ], [ 0, 3 ] ], Game::Import::Rows.garage_ring([ [ 0, 0 ], [ 6, 0 ], [ 6, 3 ], [ 0, 3 ] ], 0.0)
    assert_nil Game::Import::Rows.garage_ring([ [ 0, 5 ], [ 6, 5 ], [ 6, 8 ], [ 0, 8 ] ], 0.0), "behind the front line is a shed"
    assert_nil Game::Import::Rows.garage_ring([ [ 0, 0 ], [ 2, 0 ], [ 2, 3 ], [ 0, 3 ] ], 0.0), "two metres is not a car"
    assert_nil Game::Import::Rows.garage_ring([ [ 0, 0 ], [ 0, 6 ], [ 2, 6 ], [ 2, 0 ] ], 0.0), "a box deeper than it is wide, two metres across, is a shed"
  end

  test "a garage box carries its door and every garage is one storey" do
    garages = (rows.objects + church_rows.objects).flat_map { |o| o[:recipe]["boxes"].select { |b| b["door"] == "garage" } }
    garages.each do |box|
      assert_equal 1, box["storeys"]
      refute box["solid"]
    end
  end

  test "dwellings facing a road get a front garden that reaches it" do
    houses = rows.objects.select { |o| o[:category] == "house" }
    gardens = houses.flat_map { |o| o[:recipe]["gardens"] }
    dwellings = houses.sum { |o| o[:recipe]["dwellings"].length }

    assert_operator gardens.length, :>=, dwellings / 2, "fewer than half the estate's dwellings have a garden"
    gardens.each do |g|
      assert_operator g["depth"], :>=, Game::Import::Rows::GARDEN_MIN
      assert_operator g["depth"], :<=, Game::Import::Rows::GARDEN_MAX
    end
    houses.each do |o|
      bays = o[:recipe]["gardens"].map { |g| g["bay"] }
      assert_equal bays.uniq, bays, "#{o[:name]} gives one dwelling two gardens"
      bays.each { |b| assert_operator b, :<, o[:recipe]["dwellings"].length }
    end
    # The row this file already proves faces its road has a garden.
    row12 = rows.objects.find { |o| o[:recipe]["pands"].include?("053076") }
    assert_operator row12[:recipe]["gardens"].length, :>=, 1, "the row that faces its road has no garden"
  end

  test "a garden never lies under a box of its own bay" do
    (rows.objects + church_rows.objects).each do |o|
      z0 = o[:recipe]["band"]&.first
      Array(o[:recipe]["gardens"]).each do |g|
        o[:recipe]["boxes"].select { |b| b["bay"] == g["bay"] }.each do |box|
          assert_operator box["ring"].map(&:last).min, :>=, z0 - 0.3, "#{o[:name]}: #{box['name']} stands in bay #{g['bay']}'s garden"
        end
      end
    end
  end

  # The details a dwelling gets are decided here from the seed, never by the generator:
  # a garage in the front, glass at the back, a dakkapel on the roof. Some but not all,
  # and never where the geometry has no room.
  test "dwellings are flagged for garages, glazing and dormers by seed, where there is room" do
    houses = rows.objects.select { |o| o[:category] == "house" }
    dwellings = houses.flat_map { |o| o[:recipe]["dwellings"].map { |d| [ o, d ] } }
    %w[garage glazing dormer].each do |flag|
      flagged = dwellings.count { |_, d| d[flag] }
      assert_operator flagged, :>, 0, "no dwelling has a #{flag}"
      assert_operator flagged, :<, dwellings.length, "every dwelling has a #{flag}"
    end
    dwellings.each do |o, d|
      cols = ((d["x1"] - d["x0"]) / o[:recipe]["cell"]).round
      refute d["garage"] && cols < 6, "#{o[:name]}: a garage on a #{cols}-column front"
      refute d["garage"] && o[:recipe]["boxes"].any? { |b| b["door"] == "garage" }, "#{o[:name]}: a garage in the house AND beside it"
      if d["dormer"]
        run = (o[:recipe]["band"][1] - o[:recipe]["band"][0]) / 2.0
        rise = o[:recipe]["ridge"] - o[:recipe]["eaves"]
        assert_operator rise, :>=, 2.5, "#{o[:name]}: a dormer on a shallow roof"
        assert_operator 1.0 + 1.5 * run / rise, :<=, run - 0.5, "#{o[:name]}: a dormer with no room under the ridge"
        assert_operator d["x1"] - d["x0"], :>=, 4.5
      end
    end
  end

  test "the same seed always flags the same dwellings" do
    # Pinned literally, because "the same seed flags the same dwellings" compared against
    # itself cannot fail. Two of the eight dwellings of seed 227 get the detail with salt 1
    # at a third; change the hash and this array moves, which is the point of pinning it.
    assert_equal [ false, true, false, false, false, true, false, false ],
                 (0...8).map { |i| Game::Import::Rows.detail?(227, i, 1, 33) }
    assert_equal true, (0...100).count { |i| Game::Import::Rows.detail?(5, i, 2, 50) }.between?(30, 70),
                 "a fifty percent share should flag about half"
    refute Game::Import::Rows.detail?(5, 0, 2, 0)
    assert Game::Import::Rows.detail?(5, 0, 2, 100)
  end

  test "every flagged recipe generates" do
    (rows.objects + church_rows.objects).each do |o|
      set = Game::Building::Generator.call(o[:recipe])
      dormers = o[:recipe]["dwellings"].count { |d| d["dormer"] }
      assert_operator set.surfaces.count { |s| s.material.name == :steel && s.kind == :roof }, :>=, dormers, "#{o[:name]}: a flagged dormer was not generated"
    end
  end

  test "dwellings are flagged for panels and chimneys by seed, where the roof allows" do
    dwellings = (rows.objects + church_rows.objects).flat_map { |o| o[:recipe]["dwellings"].map { |d| [ o, d ] } }
    %w[solar chimney].each do |flag|
      flagged = dwellings.count { |_, d| d[flag] }
      assert_operator flagged, :>, 0, "no dwelling has #{flag}"
      assert_operator flagged, :<, dwellings.length, "every dwelling has #{flag}"
    end
    dwellings.each do |o, d|
      next unless d["solar"] || d["chimney"]

      assert_equal "gable", o[:recipe]["roof"], "#{o[:name]}: fittings on a flat roof"
      assert_includes %w[house apartments], o[:category], "#{o[:name]}: fittings on a #{o[:category]}"
      # Read the constant rather than its value: the gate is 2 x CHIMNEY_SIDE in the
      # importer, and a test spelling 1.8 keeps passing when the stack changes size.
      assert_operator d["x1"] - d["x0"], :>=, 2 * Game::Building::RowGenerator::CHIMNEY_SIDE,
                      "#{o[:name]}: a chimney on a dwelling narrower than its stack" if d["chimney"]
    end
  end

  test "every flagged recipe generates its fittings" do
    (rows.objects + church_rows.objects).each do |o|
      set = Game::Building::Generator.call(o[:recipe])
      chimneys = o[:recipe]["dwellings"].count { |d| d["chimney"] }
      # Brick, because a dormer's front and cheeks land on this same kind and storey --
      # `row.storeys`, above every real storey -- and glass/plaster, never brick, is what
      # tells a stack's four walls apart from a dakkapel that happens to share a dwelling.
      stacks = set.surfaces.count { |s| s.kind == :wall && s.storey == o[:recipe]["storeys"] && s.material.name == :brick }
      assert_equal chimneys * 4, stacks, "#{o[:name]}: a flagged chimney was not generated"
    end
  end

  # A dwelling flagged for solar gets an array UNLESS a dakkapel stands on the same plane and
  # leaves fewer than three clear rows above it. Panels go on the sun-facing plane and a
  # dakkapel is always on the front, so the two meet whenever the sun is on the front -- and
  # then the panels start above the dormer, or go entirely. The totals are pinned as well as
  # the rule, because a rule that swallowed every array would satisfy the rule alone.
  test "a solar flag becomes an array unless a dakkapel has taken the plane" do
    flagged = 0
    arrays = 0
    (rows.objects + church_rows.objects).each do |o|
      next unless o[:recipe]["dwellings"]

      row = Game::Building::Row.from(o[:recipe])
      sun = Game::Building::RowGenerator.sun_facing_side(row.yaw)
      row.dwellings.each_with_index do |d, i|
        next unless d.solar

        flagged += 1
        panels = Game::Building::RowGenerator.roof_section(row, d, i).any? { |s| s.patches.any? { |p| p.material == :solar } }
        arrays += 1 if panels
        next if panels

        assert Game::Building::RowGenerator.dormer_plan(row, d), "#{o[:name]} bay #{i}: no panels and no dakkapel to blame"
        assert_equal Game::Building::RowGenerator::DORMER_SIDE, sun, "#{o[:name]} bay #{i}: the dakkapel is on the other plane"
      end
    end

    assert_equal 18, flagged, "the two windows' solar flags"
    assert_equal 16, arrays, "and the arrays that fit above a dakkapel or had none to clear"
  end
end
