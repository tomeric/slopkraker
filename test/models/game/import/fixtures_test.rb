require "test_helper"

class Game::Import::FixturesTest < ActiveSupport::TestCase
  def fixtures
    Game::Import::Fixtures.new(
      slug: "sample", name: "Sample", frame: Game::Terrain::Frame.mijnstreek, origin_z: 60.0,
      bounds: [ 0, 0, 100, 100 ], spawns: [ { "position" => [ 1.0, 6.0, 2.0 ], "yaw" => 0.5 } ],
      roads: [ { "kind" => "residential", "width" => 5.5, "points" => [ [ 0, 0 ], [ 10, 0 ] ] } ],
      objects: [ { name: "row-0", x: 1.0, y: 4.0, z: 2.0, yaw: 0.1, radius: 12.0, category: "house", pands: %w[1],
                   recipe: { "kind" => "row", "yaw" => 0.1, "cell" => 1.0, "seed" => 1, "band" => [ 0.0, 9.0 ], "storeys" => 2,
                             "storey_height" => 3.0, "eaves" => 6.0, "ridge" => 8.5, "roof" => "gable",
                             "dwellings" => [ { "x0" => 0.0, "x1" => 6.0 } ], "boxes" => [], "footprint" => [ [ 0, 0 ], [ 6, 0 ], [ 6, 9 ], [ 0, 9 ] ],
                             "category" => "house", "pands" => %w[1] } } ],
      tiles: [ Game::Terrain::TileBuilder.encode(frame: Game::Terrain::Frame.mijnstreek, tx: 0, tz: 0) { 4.0 } ],
      attribution: "test"
    )
  end

  test "the fixtures load as rows with the counts the generator produces" do
    world = YAML.safe_load(fixtures.world_yaml, permitted_classes: [ Symbol ])["sample"]
    objects = YAML.safe_load(fixtures.objects_yaml, permitted_classes: [ Symbol ])
    tiles = YAML.unsafe_load(fixtures.tiles_yaml)

    assert_equal "sample", world["slug"]
    assert_equal 60.0, world["origin_z"]
    assert_equal 1, world["roads"].length
    row = objects["sample_row_0"]
    assert_equal "building", row["kind"]
    assert_equal Game::Building::Generator.call(row["recipe"]).piece_count, row["piece_count"]
    assert_equal 51 * 51 * 2, tiles["sample_tile_0_0"]["heights"].bytesize
  end

  test "every file opens with the attribution" do
    [ fixtures.world_yaml, fixtures.objects_yaml, fixtures.tiles_yaml ].each { |yaml| assert yaml.start_with?("# "), "no header" }
    assert_includes fixtures.objects_yaml, "test"
  end
end
