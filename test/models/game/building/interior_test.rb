require "test_helper"

class Game::Building::InteriorTest < ActiveSupport::TestCase
  def recipe(footprint:, **overrides)
    Game::Building::Recipe.from({
      footprint: footprint, storeys: 1, storey_height: 3.0, eaves: 3.0, ridge: 5.0,
      roof: "gable", cell: 1.0, seed: 7
    }.merge(overrides))
  end

  def rectangle(width, depth, **overrides)
    recipe(footprint: [ [ 0, 0 ], [ width, 0 ], [ width, depth ], [ 0, depth ] ], **overrides)
  end

  # A horseshoe: two wings joined at the bottom, deeper than it is wide, so the partition
  # runs east at z = 8 -- through the left wing, out over the yard, and into the right one.
  #
  #   (0,16) +---+   +---+ (12,16)
  #          |   |   |   |
  #          |   +---+   |     <- (4,6) to (8,6)
  #          |           |
  #   (0,0)  +-----------+ (12,0)
  def horseshoe
    recipe(footprint: [ [ 0, 0 ], [ 12, 0 ], [ 12, 16 ], [ 8, 16 ], [ 8, 6 ], [ 4, 6 ], [ 4, 16 ], [ 0, 16 ] ])
  end

  # The partition is laid out against the footprint's BOUNDING BOX, and both these numbers
  # are read off that box rather than off the ring -- which is what makes the L below
  # interesting rather than a special case.
  test "the partition runs down the middle of the short axis" do
    assert_equal [ [ 0.0, 7.5 ], Game::Building::Interior::EAST, 12.0 ],
                 Game::Building::Interior.partition_line(rectangle(12, 15))
    assert_equal [ [ 7.5, 0.0 ], Game::Building::Interior::SOUTH, 12.0 ],
                 Game::Building::Interior.partition_line(rectangle(15, 12))
  end

  # The surface and the reach are built from the same three numbers, so this is the claim
  # that they cannot drift: where the slab is drawn is where the glass is kept out of.
  test "the slab that is drawn stands on the line the reach is worked out from" do
    r = rectangle(12, 15)
    (origin, direction, span) = Game::Building::Interior.partition_line(r)
    slab = Game::Building::Interior.partitions(r).first

    assert_equal [ origin[0], origin[1] ], [ slab.origin.x, slab.origin.z ]
    assert_equal [ direction.x, direction.z ], [ slab.u.x, slab.u.z ]
    assert_equal span, slab.width
  end

  # A PARTITION ENDS ON THE TWO WALLS IT RUNS BETWEEN rather than crossing them: on a
  # rectangle the crossing is at fraction 0 and 1 along the partition itself, so a
  # strict-interior test finds nothing at all -- on every hand-made building there is.
  test "a rectangle is met on the two walls the partition ends against" do
    reach = Game::Building::Interior.partition_reach(rectangle(12, 15))

    assert_equal [ nil, true, nil, true ], reach.map { |r| r&.then { true } },
                 "edges 0 and 2 run along the partition; 1 and 3 are the two it ends on"
    reach.compact.each do |low, high|
      assert_in_delta 0.5, (low + high) / 2, 1e-12, "it ends at the middle of that wall"
    end
  end

  # And it never meets the two it runs parallel to, whatever the arithmetic does with a
  # zero denominator.
  test "a wall the partition is parallel to is not met" do
    assert_nil Game::Building::Interior.partition_reach(rectangle(12, 15))[0]
    assert_nil Game::Building::Interior.partition_reach(rectangle(15, 12))[1]
  end

  # THE REASON THIS IS A SEGMENT INTERSECTION AND NOT A MIDDLE COLUMN. The partition is laid
  # against the bounding box, so it does not stop at the first wall it meets: on a horseshoe
  # it crosses the outside of the left wing, the inside of it, the inside of the right wing
  # and the outside of that -- four walls, at four different fractions, and not one of them
  # is "the middle".
  test "a footprint that is not a rectangle is met more than twice" do
    reach = Game::Building::Interior.partition_reach(horseshoe)

    assert_equal [ 1, 3, 5, 7 ], reach.each_index.select { |i| reach[i] },
                 "the four walls running along z; the four running along x are parallel to it"
    assert_equal [ 0.5, 0.8, 0.2, 0.5 ],
                 reach.compact.map { |low, high| ((low + high) / 2).round(6) },
                 "an outside wall at its middle, an inside one wherever the yard put it"
  end

  # A crossing is a stretch, not a point: the partition is a slab PARTITION_THICKNESS thick
  # and it lands on every column its thickness reaches. Which is one column, except where
  # the crossing falls on a cell boundary -- 12 m over 8 columns is exactly that, and two of
  # the street's twelve houses are it.
  test "a crossing on a cell boundary lands in both columns" do
    reach = Game::Building::Interior.partition_reach(rectangle(10, 12, cell: 1.5))

    assert_equal [ 3, 4 ], Game::Building::Walls.columns(reach[1], 8)
    assert_equal [ 3, 4 ], Game::Building::Walls.columns(reach[3], 8)
  end

  test "a crossing inside a cell lands in that cell alone" do
    reach = Game::Building::Interior.partition_reach(rectangle(12, 15))

    assert_equal [ 7 ], Game::Building::Walls.columns(reach[1], 15)
    assert_equal [ 7 ], Game::Building::Walls.columns(reach[3], 15)
  end

  # Half of Walls::THICKNESS is already reserved at both ends of every wall, so a crossing
  # that comes back as column 0 or the last one costs nothing -- Walls unions the two rather
  # than testing for it.
  test "a crossing at the very end of a wall is the corner that is already reserved" do
    assert_equal [ 0 ], Game::Building::Walls.columns([ -0.01, 0.01 ], 9)
    assert_equal [ 8 ], Game::Building::Walls.columns([ 0.99, 1.01 ], 9)
    assert_empty Game::Building::Walls.columns(nil, 9)
  end

  # Meeting a wall at an angle, the slab smears along it -- the same 150 mm of plaster
  # spread over 150 mm / sin of that angle -- so a corner cut off the box gives up more of
  # itself than a square-on wall does. No footprint in any world is cut this way today; the
  # arithmetic is general because working out which walls a partition meets shape by shape
  # is exactly what it replaced.
  test "a wall met at an angle gives up the stretch the slab actually covers of it" do
    square = Game::Building::Interior.partition_reach(rectangle(12, 12))[1]
    slanted = Game::Building::Interior.partition_reach(
      recipe(footprint: [ [ 0, 0 ], [ 12, 0 ], [ 12, 12 ], [ 6, 12 ] ])
    )[3]
    length = Math.hypot(6.0, 12.0)

    assert_in_delta Game::Building::Interior::PARTITION_THICKNESS,
                    (square.last - square.first) * 12.0, 1e-12,
                    "square on, the stretch is the slab's own thickness"
    assert_in_delta Game::Building::Interior::PARTITION_THICKNESS / (12.0 / length),
                    (slanted.last - slanted.first) * length, 1e-12,
                    "at an angle it is that over the sine of it"
  end

  test "a degenerate ring has no crossing rather than a division by zero" do
    reach = Game::Building::Interior.partition_reach(recipe(footprint: [ [ 0, 0 ], [ 4, 0 ], [ 4, 0.0 ] ]))

    assert reach.all?(&:nil?)
  end
end
