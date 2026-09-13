require "test_helper"

class Game::Building::GeneratorTest < ActiveSupport::TestCase
  # The worked example: an 8 x 10m two-storey gabled house at a 1.5m cell.
  def house(**overrides)
    Game::Building::Generator.call({
      footprint: [ [ 0, 0 ], [ 8, 0 ], [ 8, 10 ], [ 0, 10 ] ],
      storeys: 2, storey_height: 3.0, eaves: 6.0, ridge: 8.5,
      roof: "gable", cell: 1.5, seed: 7
    }.merge(overrides))
  end

  # This is the regression net for "the order is part of the contract". Offsets are handed
  # out by walking the surfaces in sequence, so a reordering renumbers every piece after
  # it -- and damage recorded against a wall would come back applied to the roof.
  test "the worked example generates exactly what it is supposed to" do
    set = house

    assert_equal 16, set.surfaces.length
    assert_equal 248, set.piece_count
    assert_equal 2, set.storey_count

    assert_equal %i[wall wall wall wall wall wall wall wall
                    floor floor partition partition roof roof gable gable],
                 set.surfaces.map(&:kind)
    assert_equal [ 0, 10, 20, 34, 48, 58, 68, 82, 96, 131, 166, 176, 186, 207, 228, 238 ],
                 set.surfaces.map(&:piece_offset)
  end

  test "offsets are contiguous and cover every piece exactly once" do
    set = house
    covered = set.surfaces.flat_map { |s| (s.piece_offset...(s.piece_offset + s.piece_count)).to_a }

    assert_equal (0...set.piece_count).to_a, covered.sort
    assert_equal covered.uniq, covered, "two surfaces claim the same index"
  end

  # piece_index and at() are inverses, for every cell of every surface. The client does
  # the first and the server the second, so a disagreement would mean damage landing on a
  # different piece than the one that was hit.
  test "every cell round trips through its index" do
    set = house

    set.surfaces.each do |surface|
      surface.rows.times do |row|
        surface.cols.times do |col|
          index = surface.piece_index(row, col)
          found, found_row, found_col = set.at(index)

          assert_equal surface.piece_offset, found.piece_offset, "index #{index} found the wrong surface"
          assert_equal [ row, col ], [ found_row, found_col ], "index #{index}"
        end
      end
    end
  end

  # The rule everything else rests on. A door is a real index holding void; a gable's
  # clipped corner is a real index holding void. If openings removed indices instead, both
  # Ruby and JavaScript would have to cull identically forever.
  test "openings and clipping never remove a piece index" do
    with_openings = house(seed: 7)
    bare = house(seed: 7, storeys: 2)

    assert_equal bare.piece_count, with_openings.piece_count

    walls = with_openings.surfaces.select { |s| s.kind == :wall }
    assert(walls.any? { |s| s.patches.any? }, "the example should have openings at all")
    walls.each do |surface|
      assert_equal surface.cols * surface.rows, surface.piece_count
    end
  end

  test "a gable is clipped with void rather than by shrinking its grid" do
    gables = house.surfaces.select { |s| s.kind == :gable }

    assert_equal 2, gables.length
    gables.each do |gable|
      assert_equal gable.cols * gable.rows, gable.piece_count
      voids = gable.patches.select { |p| p.material == :void }
      assert_not_empty voids, "the corners above the pitch should be void"
      # The apex column stays: a gable with nothing at the top is not a gable.
      assert_equal :brick, gable.material_at(gable.rows - 1, gable.cols / 2).name
    end
  end

  test "the same recipe always generates the same building" do
    a = house
    b = house

    assert_equal a.surfaces.map(&:to_spec), b.surfaces.map(&:to_spec)
  end

  test "a different seed moves the windows without changing the piece count" do
    assert_equal house(seed: 1).piece_count, house(seed: 2).piece_count
    assert_not_equal house(seed: 1).surfaces.map(&:to_spec),
                     house(seed: 2).surfaces.map(&:to_spec)
  end

  # The prompt's list: walls, glass windows, wooden frames, doors, floors, roofs.
  test "one house carries every material" do
    set = house
    used = set.piece_count.times.map { |i| set.material_at(i).name }.uniq

    assert_equal Game::Materials.names.sort, used.sort
  end

  test "the front door is timber, on the ground floor, with a lintel over it" do
    front = house.surfaces.first

    assert_equal :wall, front.kind
    assert_equal 0, front.storey
    door = (0...front.cols).find { |col| front.material_at(0, col).name == :timber }
    assert door, "the ground floor of the first wall should have a door"
    assert_equal :steel, front.material_at(1, door).name, "a lintel belongs above an opening"
  end

  test "windows are glass and sit on the floor of their storey" do
    wall = house.surfaces.find { |s| s.kind == :wall && s.storey == 1 }
    glass = (0...wall.cols).select { |col| wall.material_at(0, col).name == :glass }

    assert_not_empty glass
    glass.each { |col| assert_equal :steel, wall.material_at(1, col).name }
  end

  test "a flat roof is one deck rather than two slopes and two ends" do
    set = house(roof: "flat")
    roofs = set.surfaces.select { |s| s.kind == :roof }

    assert_equal 1, roofs.length
    assert_empty set.surfaces.select { |s| s.kind == :gable }
  end

  test "storeys each get a deck and a partition" do
    set = house

    assert_equal 2, set.surfaces.count { |s| s.kind == :floor }
    assert_equal 2, set.surfaces.count { |s| s.kind == :partition }
    assert_equal :concrete, set.surfaces.find { |s| s.kind == :floor }.material.name,
                 "the ground slab should be the last thing to give"
  end

  # What the collapse rule weighs. A wall of windows holds nothing up, so the structural
  # area of a storey has to be less than its raw area.
  test "structural area discounts glass and doorways" do
    set = house
    storey = 0
    walls = set.for_storey(storey).select { |s| %i[wall partition].include?(s.kind) }
    raw = walls.sum { |s| s.piece_count * s.cell_area }

    assert_operator set.structural_area(storey), :<, raw
    assert_operator set.structural_area(storey), :>, 0
  end

  test "the ridge follows the longer axis" do
    wide = Game::Building::Generator.call(
      footprint: [ [ 0, 0 ], [ 12, 0 ], [ 12, 6 ], [ 0, 6 ] ],
      storeys: 1, eaves: 3.0, ridge: 5.0, roof: "gable", cell: 1.5, seed: 1
    )
    gable = wide.surfaces.find { |s| s.kind == :gable }

    # A gable end closes the SHORT axis, so on a 12 x 6 house it spans 6m, not 12m.
    assert_in_delta 6.0, gable.width, 1e-9
  end
end
