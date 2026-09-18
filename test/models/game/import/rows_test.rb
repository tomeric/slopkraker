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
end
