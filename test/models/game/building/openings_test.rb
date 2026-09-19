require "test_helper"

class Game::Building::OpeningsTest < ActiveSupport::TestCase
  # Two walls meeting at a corner each straddle their own plane, so the perpendicular one
  # eats half a thickness into the end cell; an interior partition does the same in the
  # middle of the wall it meets. Glass in one of those columns is a pane with a wall
  # through it, so the caller -- the only thing that knows the building -- hands the list
  # down and nothing glazed may stand in it.
  test "no window stands in a column another wall lands in" do
    openings = Game::Building::Openings.new(seed: 3, style: :annex)
    reserved = [ 0, 4, 8 ]
    patches = openings.for_wall(edge: 1, storey: 0, cols: 9, rows: 3, reserved: reserved)

    glass = patches.select { |p| p.material == :glass }
    assert glass.any?, "reserving three columns should not empty the wall"
    glass.each do |p|
      (p.col0..p.col1).each { |c| assert_not_includes reserved, c, "a pane stands in column #{c}" }
    end
  end

  # A door in a corner is a detail; a door that vanishes is a house you cannot enter. The
  # garage door counts as a door for the same reason and for one more: Gardens asks the
  # same object for `garage_columns` so the drive through the hedge lines up with it, and
  # a garage door moved here and not there is a drive to a brick wall.
  test "a door is placed whatever lands on it" do
    openings = Game::Building::Openings.new(seed: 2, style: :house)
    patches = openings.for_wall(edge: 0, storey: 0, cols: 6, rows: 3, reserved: (0...6).to_a)

    assert patches.any? { |p| p.material == :door }, "a house you cannot enter"
  end

  test "a garage door stands where the drive meets it, reserved or not" do
    openings = Game::Building::Openings.new(seed: 2, style: :house, garage: true)
    patches = openings.for_wall(edge: 0, storey: 0, cols: 8, rows: 3, reserved: (0...8).to_a)
    doors = patches.select { |p| p.material == :door }.map { |p| (p.col0..p.col1).to_a }.flatten

    assert_equal openings.door_columns(8) + openings.garage_columns(8), doors.sort,
                 "the door and the drive have to agree about which columns they are in"
  end

  # Every style, every reasonable face, every seed in a spread: a reserved column is never
  # glazed. The styles differ in how they pick their windows -- runs, every other column,
  # every third, one -- so this is the only assertion that covers all four paths at once.
  test "a reserved column holds no glass in any style" do
    Game::Building::Openings::STYLES.each_key do |style|
      (2..14).each do |cols|
        reserved = [ 0, cols / 2, cols - 1 ].uniq
        (0..7).each do |seed|
          openings = Game::Building::Openings.new(seed: seed, style: style, garage: true, glazing: true)
          (0..3).each do |edge|
            (0..1).each do |storey|
              openings.for_wall(edge: edge, storey: storey, cols: cols, rows: 3, reserved: reserved).each do |patch|
                next unless patch.material == :glass

                (patch.col0..patch.col1).each do |col|
                  assert_not_includes reserved, col,
                                      "#{style} glazed column #{col} of #{cols} at seed #{seed}, edge #{edge}, storey #{storey}"
                end
              end
            end
          end
        end
      end
    end
  end

  # A run is one or two cells. Reserving the column it starts in should leave the other
  # cell glazed rather than take the window away -- shortened, not dropped.
  test "a run that would cover a reserved column is shortened rather than dropped" do
    openings = Game::Building::Openings.new(seed: 1, style: :annex)
    before = openings.for_wall(edge: 1, storey: 0, cols: 12, rows: 3).select { |p| p.material == :glass }
    pair = before.find { |p| p.col1 > p.col0 }

    assert pair, "seed 1 should give this face at least one two-cell run"

    after = openings.for_wall(edge: 1, storey: 0, cols: 12, rows: 3, reserved: [ pair.col0 ]).select { |p| p.material == :glass }
    kept = after.find { |p| p.col0 == pair.col0 + 1 }

    assert kept, "the run should have given up its first cell, not the window"
    assert_equal pair.col1, kept.col1
  end

  # A two-cell face is nothing BUT corners, so it gets a blank wall rather than a pane with
  # a wall through it. Measured over the five worlds: 25 of 1049 walls lose their last
  # window this way, 19 of them faces two or three cells wide, and no building anywhere
  # ends up without glass.
  test "a face that is all corner gets no window rather than a buried one" do
    openings = Game::Building::Openings.new(seed: 1, style: :chapel)
    patches = openings.for_wall(edge: 1, storey: 0, cols: 2, rows: 3, reserved: [ 0, 1 ])

    assert_empty patches.select { |p| p.material == :glass }
    assert_not_empty openings.for_wall(edge: 1, storey: 0, cols: 2, rows: 3).select { |p| p.material == :glass },
                     "a two-cell face did glaze one of its two corners before"
  end

  test "reserving nothing leaves every style exactly as it was" do
    Game::Building::Openings::STYLES.each_key do |style|
      (3..12).each do |cols|
        (0..5).each do |seed|
          openings = Game::Building::Openings.new(seed: seed, style: style, garage: true, glazing: true)
          (0..3).each do |edge|
            assert_equal openings.for_wall(edge: edge, storey: 0, cols: cols, rows: 3).map(&:to_spec),
                         openings.for_wall(edge: edge, storey: 0, cols: cols, rows: 3, reserved: []).map(&:to_spec),
                         "#{style} at #{cols} columns, seed #{seed}, edge #{edge}"
          end
        end
      end
    end
  end
end
