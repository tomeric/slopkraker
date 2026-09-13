require "test_helper"

class Game::Building::BlocksTest < ActiveSupport::TestCase
  def house(**overrides)
    Game::Building::Generator.call({
      footprint: [ [ 0, 0 ], [ 12, 0 ], [ 12, 15 ], [ 0, 15 ] ],
      storeys: 3, storey_height: 3.0, eaves: 9.0, ridge: 12.75,
      roof: "gable", cell: 1.0, seed: 7
    }.merge(overrides))
  end

  def walls(set = house)
    set.surfaces.select { |surface| surface.kind == :wall }
  end

  test "every cell of a blocked surface belongs to exactly one block" do
    walls.each do |wall|
      assert_equal wall.cols * wall.rows, wall.blocks.length
      assert(wall.blocks.none?(&:nil?), "a cell was left out of the tiling")
    end
  end

  test "blocks are contiguous" do
    wall = walls.first
    cells_by_block = (0...wall.blocks.length).group_by { |index| wall.blocks[index] }

    cells_by_block.each_value do |cells|
      next if cells.length == 1

      # Walk the block from one of its cells; every cell has to be reachable through
      # shared edges, or it is two blocks sharing an id.
      seen = [ cells.first ]
      queue = [ cells.first ]
      until queue.empty?
        index = queue.shift
        row, col = index.divmod(wall.cols)
        [ [ 0, -1 ], [ 0, 1 ], [ -1, 0 ], [ 1, 0 ] ].each do |drow, dcol|
          r = row + drow
          c = col + dcol
          next if r.negative? || c.negative? || r >= wall.rows || c >= wall.cols

          neighbour = r * wall.cols + c
          next unless cells.include?(neighbour)
          next if seen.include?(neighbour)

          seen << neighbour
          queue << neighbour
        end
      end

      assert_equal cells.sort, seen.sort, "block #{wall.blocks[cells.first]} is in two parts"
    end
  end

  # The rule that keeps a window a window. Grouped with the brick around it, breaking a
  # pane would take half a wall with it.
  test "a block never spans two materials" do
    walls.each do |wall|
      (0...wall.blocks.length).group_by { |index| wall.blocks[index] }.each_value do |cells|
        materials = cells.map { |index| wall.material_at(*index.divmod(wall.cols)).name }.uniq

        assert_equal 1, materials.length, "a block mixes #{materials.inspect}"
      end
    end
  end

  test "glass ends up on its own" do
    wall = walls.find { |surface| surface.blocks.any? { |_| true } && glass_cells(surface).any? }
    blocks = glass_cells(wall).map { |index| wall.blocks[index] }

    assert_equal blocks.uniq.length, blocks.length, "two panes share a block"
  end

  test "the tiling actually groups things" do
    wall = walls.first

    assert_operator wall.blocks.uniq.length, :<, wall.blocks.length,
      "every cell came out as its own block, which is the grid we started with"
  end

  # Two clients disagreeing about which cells belong together would disagree about what a
  # single hit destroyed.
  test "the same surface always tiles the same way" do
    assert_equal walls.map(&:blocks), walls(house).map(&:blocks)
  end

  test "a different seed tiles differently" do
    assert_not_equal walls(house(seed: 1)).map(&:blocks), walls(house(seed: 2)).map(&:blocks)
  end

  # A roof is already made of tiles and a floor of slabs; grouping them buys nothing and
  # would make a roof come off in sheets.
  test "roofs and floors keep the plain grid" do
    house.surfaces.each do |surface|
      next if %i[wall partition gable].include?(surface.kind)

      assert_nil surface.blocks, "#{surface.kind} should not be blocked"
    end
  end

  test "blocks reach the wire" do
    spec = walls.first.to_spec

    assert_equal spec[:cols] * spec[:rows], spec[:blocks].length
  end

  private
    def glass_cells(surface)
      (0...surface.cols * surface.rows).select do |index|
        surface.material_at(*index.divmod(surface.cols)).name == :glass
      end
    end
end
