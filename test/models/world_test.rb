require "test_helper"

class WorldTest < ActiveSupport::TestCase
  def build(**overrides)
    World.new({
      slug: "test", name: "Test", bounds: [ 0, 0, 1, 1 ], spawns: [], content_digest: "abc123def456"
    }.merge(overrides))
  end

  test "a default world's grids nest" do
    assert_predicate build, :valid?
  end

  # Tiles share their edge samples. A step that does not divide the tile means the last
  # sample lands short of the edge, so neighbouring tiles disagree about the height along
  # the boundary between them -- an invisible cliff a car falls off.
  test "a height step that does not divide the tile is rejected" do
    world = build(height_step: 7)

    assert_not world.valid?
    assert_match(/divide tile_size/, world.errors[:height_step].first)
  end

  # An object belongs to exactly one chunk. If chunks did not nest inside tiles, a chunk
  # could span two of them and there would be no single tile to sample its terrain from.
  test "a chunk size that does not divide the tile is rejected" do
    world = build(chunk_size: 300)

    assert_not world.valid?
    assert_match(/straddles/, world.errors[:chunk_size].first)
  end

  test "samples per edge is one more than the cells" do
    assert_equal 101, build(tile_size: 500, height_step: 5).height_n
    assert_equal 51, build(tile_size: 500, height_step: 10).height_n
  end

  test "a world hands out a frame carrying its own origin" do
    frame = build(srid: 28_992, origin_x: 185_000.0, origin_y: 330_000.0).frame

    assert_equal 28_992, frame.srid
    assert_equal [ 0.0, 0.0 ], frame.to_game(185_000.0, 330_000.0)
  end

  test "slugs are unique" do
    build.save!

    assert_not build.valid?
  end

  # The fixture, the seed and the browser all have to stand on the same ground, which is
  # only true if they all come from one definition. The world's own sampler is how Ruby
  # asks what that ground is.
  test "a world with tiles samples its own terrain" do
    hills = worlds(:hills)

    assert_equal 4, hills.terrain_tiles.count
    assert_equal 41, hills.height_n
    # Exactly on a sample: only the centimetre rounding between them.
    assert_in_delta Game::Terrain::Hills.height_at(0.0, 0.0), hills.sampler.height_at(0.0, 0.0), 0.005
    # Between samples: a triangle of a curved function, so a few centimetres of sag.
    assert_in_delta Game::Terrain::Hills.height_at(-123.4, 56.7), hills.sampler.height_at(-123.4, 56.7), 0.1
  end

  test "the hills spawn stands two metres above the hilltop" do
    spawn = worlds(:hills).spawn_points.first

    assert_in_delta Game::Terrain::Hills.height_at(0.0, 0.0) + 2.0, spawn.position.y, 0.01
  end

  test "a world without tiles samples its fallback" do
    assert_equal 0.0, worlds(:flat).sampler.height_at(12.0, -34.0)
    assert_equal(-1.0, worlds(:flat).sampler(fallback: -1.0).height_at(12.0, -34.0))
  end

  # The house's base is the mean of the ground under its corners: buried a little uphill,
  # clear a little downhill, and on a slope on purpose so that a test can tell rubble
  # placed on the terrain from rubble placed at the building's own height.
  test "the hills house stands on a slope at the mean height of its corners" do
    house = world_objects(:hills_house)
    corners = [ [ 0, 0 ], [ 12, 0 ], [ 12, 15 ], [ 0, 15 ] ]
      .map { |dx, dz| Game::Terrain::Hills.height_at(house.x + dx, house.z + dz) }

    assert_operator corners.max - corners.min, :>, 0.5, "the site is too level to prove anything"
    assert_in_delta corners.sum / 4, house.y, 0.01
  end

  test "a world without tiles has no terrain manifest" do
    assert_nil worlds(:flat).terrain
  end

  test "a world with tiles hands out a manifest carrying its frame" do
    manifest = worlds(:hills).terrain

    assert_equal 4, manifest.tiles.length
    assert_equal 41, manifest.to_spec[:height_n]
    assert_equal 4, manifest.to_spec[:tiles].length
  end
end
