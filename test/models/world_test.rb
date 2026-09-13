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
end
