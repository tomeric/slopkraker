require "test_helper"

class Game::Chunks::GridTest < ActiveSupport::TestCase
  def grid
    @grid ||= Game::Chunks::Grid.new(
      frame: Game::Terrain::Frame.new(tile_size: 500, chunk_size: 125)
    )
  end

  test "a point resolves to the chunk containing it" do
    assert_equal [ 0, 0 ], grid.of(0.0, 0.0)
    assert_equal [ 0, 0 ], grid.of(124.9, 124.9)
    assert_equal [ 1, 1 ], grid.of(125.0, 125.0)
    assert_equal [ -1, -1 ], grid.of(-1.0, -1.0)
  end

  test "a chunk knows its own corner and centre" do
    assert_equal [ 250, 375 ], grid.origin_of(2, 3)
    assert_equal [ 312.5, 437.5 ], grid.centre_of(2, 3)
  end

  test "the ring is ordered nearest first" do
    chunks = grid.within(62.5, 62.5, 300.0)

    assert_equal [ 0, 0 ], chunks.first
    distances = chunks.map { |cx, cz| grid.distance_to(62.5, 62.5, cx, cz) }
    assert_equal distances.sort, distances, "a streamer loads nearest first"
  end

  test "the ring reaches far enough to cover the radius" do
    chunks = grid.within(62.5, 62.5, 300.0)

    chunks.each do |cx, cz|
      assert_operator grid.distance_to(62.5, 62.5, cx, cz), :<=, 300.0
    end
    # Anything whose centre is inside the radius must be present, so nothing pops in late.
    assert_includes chunks, [ 2, 0 ]
    assert_not_includes chunks, [ 4, 4 ]
  end

  test "the ring works at negative coordinates" do
    chunks = grid.within(-500.0, -500.0, 200.0)

    assert_includes chunks, [ -4, -4 ]
    assert(chunks.all? { |cx, cz| cx.negative? && cz.negative? })
  end

  test "a radius smaller than a chunk still yields the one the player is standing in" do
    assert_equal [ [ 0, 0 ] ], grid.within(62.5, 62.5, 1.0)
  end
end
