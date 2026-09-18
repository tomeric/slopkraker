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
end
