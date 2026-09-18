require "test_helper"

class Game::Import::RowsTest < ActiveSupport::TestCase
  def files = Rails.root.join("test/fixtures/files/geleen")
  def rows
    @rows ||= Game::Import::Rows.new(
      window: JSON.parse(files.join("window.json").read), clusters: JSON.parse(files.join("rows.json").read),
      frame: Game::Terrain::Frame.mijnstreek, roads: JSON.parse(files.join("roads.json").read)
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
