require "test_helper"

class Game::Building::GeneratorTest < ActiveSupport::TestCase
  # The worked example, and deliberately the same building the targets fixture seeds: one
  # canonical house rather than a test house and a real house that can drift apart.
  def house(**overrides)
    Game::Building::Generator.call({
      footprint: [ [ 0, 0 ], [ 12, 0 ], [ 12, 15 ], [ 0, 15 ] ],
      storeys: 3, storey_height: 3.0, eaves: 9.0, ridge: 12.75,
      roof: "gable", cell: 1.0, seed: 7
    }.merge(overrides))
  end

  # This is the regression net for "the order is part of the contract". Offsets are handed
  # out by walking the surfaces in sequence, so a reordering renumbers every piece after
  # it -- and damage recorded against a wall would come back applied to the roof.
  test "the worked example generates exactly what it is supposed to" do
    set = house

    assert_equal 23, set.surfaces.length
    assert_equal 1553, set.piece_count
    assert_equal 3, set.storey_count

    assert_equal %i[wall wall wall wall wall wall wall wall wall wall wall wall
                    floor floor floor partition partition partition roof roof gable gable
                    rubble],
                 set.surfaces.map(&:kind)
    assert_equal [ 0, 36, 72, 108, 153, 198, 243, 279, 315, 351, 396, 441,
                   486, 666, 846, 1026, 1062, 1098, 1134, 1246, 1358, 1406, 1454 ],
                 set.surfaces.map(&:piece_offset)
  end

  test "a single house is one bay with nothing shared" do
    set = house

    assert_equal [ 0 ], set.bays
    assert_empty set.for_bay(0)[:shared]
    assert_equal set.surfaces.reject { |s| s.kind == :rubble }.length, set.for_bay(0)[:own].length
  end

  # Rubble is generated last and must stay last. Every index before it keeps the number it
  # had before rubble existed, which is what let a building start reserving space for its
  # own wreckage without renumbering a world that had already been played and damaged.
  test "rubble is appended after every surface the building is made of" do
    set = house

    assert_equal :rubble, set.surfaces.last.kind
    assert_equal 1, set.surfaces.count { |s| s.kind == :rubble }
    assert_equal 1454, set.surfaces.last.piece_offset,
                 "the building's own pieces must keep the indices they had"
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
    set = house
    patched = set.surfaces.select { |surface| surface.patches.any? }

    assert_not_empty patched, "the example should have openings and clipping at all"
    # Every surface holds exactly its grid, patches or not. A door, a window and a clipped
    # gable corner all occupy an index; only what is drawn there changes.
    set.surfaces.each do |surface|
      assert_equal surface.cols * surface.rows, surface.piece_count, surface.kind
    end
    assert_equal set.surfaces.sum { |s| s.cols * s.rows }, set.piece_count
  end

  test "a gable is clipped with void rather than by shrinking its grid" do
    gables = house.surfaces.select { |s| s.kind == :gable }

    assert_equal 2, gables.length
    gables.each do |gable|
      assert_equal gable.cols * gable.rows, gable.piece_count
      voids = gable.patches.select { |p| p.material == :void }
      assert_not_empty voids, "the corners above the pitch should be void"
      # The apex column stays: a gable with nothing at the top is not a gable.
      assert_equal :brick, gable.material_at(gable.rows - 2, gable.cols / 2).name
    end

    # Judged on the cell's top edge rather than its centre, so no kept cell stands proud
    # of the roof. Judged on the centre, the ridge grew a row of teeth.
    test_gable = gables.first
    test_gable.cols.times do |col|
      across = (col + 0.5) / test_gable.cols
      line = 1.0 - (2.0 * across - 1.0).abs
      kept = (0...test_gable.rows).count { |row| test_gable.material_at(row, col).name != :void }

      assert_operator kept.to_f / test_gable.rows, :<=, line + 1e-9,
        "column #{col} stands above the pitch"
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

  # Wide and tall enough to drive through, which is the whole point of a hollow building,
  # and spanned by the one piece of steel in the house. A lintel over a single 1m window
  # was just a dark square in the middle of a wall.
  test "the front door is a timber opening under a steel lintel" do
    front = house.surfaces.first

    assert_equal :wall, front.kind
    assert_equal 0, front.storey

    door = (0...front.cols).select { |col| front.material_at(0, col).name == :timber }
    assert_equal 3, door.length, "a door you cannot drive through is a wall"
    assert_equal door, door.first.upto(door.last).to_a, "the door should be contiguous"

    door.each do |col|
      assert_equal :timber, front.material_at(1, col).name, "the door is two courses tall"
      assert_equal :steel, front.material_at(2, col).name, "a lintel spans the opening"
    end
  end

  test "a wall too narrow for a door gets none rather than being all door" do
    narrow = Game::Building::Openings.new(seed: 1).for_wall(edge: 0, storey: 0, cols: 2, rows: 3)
    assert narrow.none? { |p| p.material == :timber }
  end

  # A window on the floor is what a two-row storey forces. Three rows is what buys it a
  # sill to stand on, and is the reason the grid got finer.
  test "windows sit a course above the floor" do
    wall = house.surfaces.find { |s| s.kind == :wall && s.storey == 1 }

    assert_equal 3, wall.rows
    assert_not_empty (0...wall.cols).select { |col| wall.material_at(1, col).name == :glass }
    assert_empty (0...wall.cols).select { |col| wall.material_at(0, col).name == :glass },
                 "nothing should be glazed at floor level"
  end

  test "a flat roof is one deck rather than two slopes and two ends" do
    set = house(roof: "flat")
    roofs = set.surfaces.select { |s| s.kind == :roof }

    assert_equal 1, roofs.length
    assert_empty set.surfaces.select { |s| s.kind == :gable }
  end

  test "storeys each get a deck and a partition" do
    set = house

    assert_equal 3, set.surfaces.count { |s| s.kind == :floor }
    assert_equal 3, set.surfaces.count { |s| s.kind == :partition }
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
