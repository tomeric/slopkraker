require "test_helper"

class Game::Import::DemTest < ActiveSupport::TestCase
  # A 3 x 3 grid at 10 m: origin (100, 130) is the top-left corner, rows run south, and
  # the height is 1 + x/10 + y/100 so every answer can be worked by hand.
  def dem
    @dem ||= begin
      path = Rails.root.join("tmp/dem_test.raw")
      samples = (0...3).flat_map { |row| (0...3).map { |col| 1.0 + (100 + col * 10 + 5) / 10.0 + (130 - row * 10 - 5) / 100.0 } }
      path.binwrite(samples.pack("e*"))
      Game::Import::Dem.new(path: path, origin_x: 100.0, origin_y: 130.0, step: 10.0, cols: 3, rows: 3)
    end
  end

  test "a sample centre reads back exactly" do
    assert_in_delta 1.0 + 10.5 + 1.25, dem.height_at(105.0, 125.0), 1e-6
  end

  test "between samples it interpolates" do
    assert_in_delta 1.0 + 11.0 + 1.25, dem.height_at(110.0, 125.0), 1e-6
    assert_in_delta 1.0 + 10.5 + 1.20, dem.height_at(105.0, 120.0), 1e-6
  end

  test "outside the grid it refuses rather than guessing" do
    assert_raises(Game::Import::Dem::NoData) { dem.height_at(50.0, 125.0) }
  end
end
