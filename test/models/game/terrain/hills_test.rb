require "test_helper"

class Game::Terrain::HillsTest < ActiveSupport::TestCase
  Hills = Game::Terrain::Hills

  # Every term is a cosine, so every gradient is zero at the origin: the spawn stands on
  # a level hilltop rather than a slope it would roll off before the player touched a key.
  test "the spawn stands on a level hilltop" do
    top = Hills.height_at(0.0, 0.0)

    assert_operator top, :>, 5.0
    [ [ 0.5, 0.0 ], [ -0.5, 0.0 ], [ 0.0, 0.5 ], [ 0.0, -0.5 ] ].each do |x, z|
      assert_in_delta top, Hills.height_at(x, z), 0.01, "not level at (#{x}, #{z})"
    end
  end

  test "the relief is real and fits a tile with room to spare" do
    heights = (-200..200).step(5).flat_map { |x| (-200..200).step(5).map { |z| Hills.height_at(x, z) } }

    assert_operator heights.min, :>, -20.0
    assert_operator heights.max, :<, 20.0
    assert_operator heights.max - heights.min, :>, 10.0, "flat enough to prove nothing"
  end

  # A cell's two triangles are different planes only when its four corners are not
  # coplanar, and the probe test's power to catch the wrong diagonal rests entirely on
  # that. Half the twist is how far apart the two diagonals put the cell's centre.
  test "cells twist enough for the diagonal to matter" do
    twists = (-200...200).step(5).flat_map do |x|
      (-200...200).step(5).map do |z|
        (Hills.height_at(x, z) + Hills.height_at(x + 5, z + 5) -
         Hills.height_at(x + 5, z) - Hills.height_at(x, z + 5)).abs / 2
      end
    end

    assert_operator twists.max, :>, 0.03
  end

  test "four tiles cover the world exactly and encode deterministically" do
    assert_equal [ [ -1, -1 ], [ -1, 0 ], [ 0, -1 ], [ 0, 0 ] ], Hills::TILES
    assert_equal 41, Hills::FRAME.height_n

    tile = Hills.tile(0, 0)
    assert_equal 41 * 41 * 2, tile.heights.bytesize
    assert_equal tile.heights, Hills.tile(0, 0).heights
  end

  test "a base height lies within the ground under the corners" do
    corners = [ [ -120.0, -135.0 ], [ -108.0, -135.0 ], [ -108.0, -120.0 ], [ -120.0, -120.0 ] ]
      .map { |x, z| Hills.height_at(x, z) }
    base = Hills.base_height(-120.0, -135.0, 12.0, 15.0)

    assert_operator base, :>=, corners.min
    assert_operator base, :<=, corners.max
  end
end
