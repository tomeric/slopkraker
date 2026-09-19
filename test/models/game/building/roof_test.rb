require "test_helper"

# The clip that shapes a gable to the roof over it.
class Game::Building::RoofTest < ActiveSupport::TestCase
  Roof = Game::Building::Roof

  # The roof line as the clip draws it: `1 - |2t - 1|` of the gable's height, at fraction
  # `t` across. The same function `gableCaps` uses on the client to fill the steps.
  def line(t) = 1.0 - (2.0 * t - 1.0).abs

  def voids(cols, rows)
    Roof.clip(cols, rows).map { |p| [ p.col0, p.row0 ] }.to_set
  end

  # THE ASSERTION THIS FILE EXISTS FOR. A cell is a rectangle spanning a whole column, and
  # the roof over it is a slope -- so the line at the column's middle says nothing about
  # what the cell does at its outer edge. Judged on the middle, 166 of the 746 gable cells
  # in the seeded worlds stood proud of their own roof, the worst by 1.92 m through tiles
  # 0.2 m thick: brick teeth stepping up the verge, photographed from the kerb on
  # 2026-09-19. Judged on the LOWEST corner, a kept cell is wholly under the roof
  # everywhere across its width, and the caps fill what that leaves.
  #
  # Every shape here has room for at least one whole cell under the slope. The shapes that
  # do not are the next test, and they are the one exception to this rule.
  test "no kept cell stands proud of the roof anywhere across its width" do
    [ [ 9, 3 ], [ 12, 4 ], [ 7, 2 ], [ 20, 9 ], [ 5, 2 ] ].each do |cols, rows|
      void = voids(cols, rows)
      assert_operator void.size, :<, cols * rows, "#{cols}x#{rows} should have room for a whole cell"

      cols.times do |col|
        low = [ line(col.to_f / cols), line((col + 1.0) / cols) ].min

        rows.times do |row|
          next if void.include?([ col, row ])

          top = (row + 1).to_f / rows
          assert_operator top, :<=, low + 1e-9,
            "#{cols}x#{rows}: cell [#{col}, #{row}] tops out at #{top} where the roof is #{low}"
        end
      end
    end
  end

  # THE ONE EXCEPTION, and it is not a softening of the rule -- it is the rule meeting a
  # shape it cannot serve. A cap hangs on a STANDING cell, so a gable clipped to nothing is
  # not a triangle of caps but a hole where a wall was. A gable one row tall has no cell
  # wholly under a slope that rises less than a cell, and one two columns wide has a roof
  # line of zero at the outer edge of both, so the strict rule empties them. They keep what
  # the middle rule kept instead, standing a little proud, because a brick a few
  # centimetres out of a roof is a far smaller lie than a missing gable.
  test "a gable too shallow for a whole cell keeps a wall rather than vanishing" do
    [ [ 3, 1 ], [ 5, 1 ], [ 2, 2 ], [ 2, 4 ] ].each do |cols, rows|
      void = voids(cols, rows)

      assert_operator void.size, :<, cols * rows,
        "#{cols}x#{rows} came out entirely void -- nothing for a cap to hang on"
    end
  end

  # And the fallback really is the rule it replaces, not something new: the middle column of
  # a one-row gable is the cell the old rule kept, and the outermost is the one it dropped.
  test "the fallback is the middle rule, cell for cell" do
    void = voids(5, 1)

    assert_includes void, [ 0, 0 ], "the outermost column is all roof and no wall"
    assert_not_includes void, [ 2, 0 ], "the column under the ridge keeps its course"
  end

  # It must not clip an ordinary gable away either: the wall under a ridge is still a wall.
  test "the columns under the ridge keep their cells" do
    cols, rows = 12, 4
    void = voids(cols, rows)

    standing = (0...cols).count { |col| (0...rows).any? { |row| !void.include?([ col, row ]) } }
    assert_operator standing, :>=, cols / 2, "a gable clipped to nothing is not a gable"
    assert_not void.include?([ cols / 2, 0 ]), "the column beside the ridge keeps its bottom course"
  end
end
