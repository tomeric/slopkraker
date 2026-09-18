require "test_helper"

class Game::Building::RowTest < ActiveSupport::TestCase
  # Two dwellings of 6 x 9 m, two storeys of 3 m, one gable, 1 m cells, no boxes. Chosen so
  # every count can be worked by hand: a 6 m wall is 6 x 3 = 18 cells, a 9 m one 27, a deck
  # 54, a partition across the 6 m width 18, a roof section 6.4 x 5.15 -> 6 x 5 = 30, a
  # gable end 9 x 3 = 27, and the rubble grid ceil(18/2) x ceil(15/2) = 9 x 8 = 72.
  def pair(**overrides)
    Game::Building::Generator.call({
      "kind" => "row", "category" => "house", "pands" => %w[000001 000002],
      "yaw" => 0.0, "cell" => 1.0, "seed" => 1,
      "band" => [ 0.0, 9.0 ], "storeys" => 2, "storey_height" => 3.0, "eaves" => 6.0, "ridge" => 8.5, "roof" => "gable",
      "dwellings" => [ { "x0" => 0.0, "x1" => 6.0 }, { "x0" => 6.0, "x1" => 12.0 } ],
      "boxes" => [],
      "footprint" => [ [ 0, 0 ], [ 12, 0 ], [ 12, 9 ], [ 0, 9 ] ]
    }.merge(overrides))
  end

  # THE CONTRACT. Offsets are handed out in this order; change the order and damage
  # recorded against one wall comes back on another.
  test "the worked example generates exactly what it is supposed to" do
    set = pair

    assert_equal 29, set.surfaces.length
    assert_equal 840, set.piece_count
    assert_equal 2, set.storey_count
    assert_equal %i[wall] * 14 + %i[floor floor partition partition floor floor partition partition
                                    roof roof gable roof roof gable rubble],
                 set.surfaces.map(&:kind)
    assert_equal [ 0, 18, 36, 54, 72, 90, 108, 126, 144, 171, 198, 225, 252, 279,
                   306, 360, 414, 432, 450, 504, 558, 576, 594, 624, 654, 681, 711, 741, 768 ],
                 set.surfaces.map(&:piece_offset)
  end

  test "every surface knows its bay, and the party wall is shared" do
    set = pair
    walls = set.surfaces.select { |s| s.kind == :wall }

    assert_equal [ 0 ] * 4 + [ 1 ] * 4, walls.first(8).map(&:bay), "front and back walls per dwelling"
    assert_equal [ 1, 1, 0, 0 ], walls[8, 4].map(&:bay), "the right end belongs to the last dwelling, the left to the first"
    assert_equal [ [ 0, 1 ], [ 0, 1 ] ], walls[12, 2].map(&:between), "party walls, one per storey"
    assert_equal [ 0, 1 ], set.bays
    assert_equal [ 0, 0, 0, 1, 1, 1 ], set.surfaces.select { |s| %i[roof gable].include?(s.kind) }.map(&:bay)
  end

  test "rubble is last and carries a bay per cell" do
    rubble = pair.surfaces.last

    assert_equal :rubble, rubble.kind
    assert_equal rubble.cols * rubble.rows, rubble.bays.length
    assert_equal [ 0, 1 ], rubble.bays.uniq.sort
    assert_equal 0, rubble.bays[rubble.cols / 4], "a heap on the left half belongs to the first dwelling"
    assert_equal 1, rubble.bays[rubble.cols - 1 - rubble.cols / 4], "and one on the right to the second"
  end

  test "every dwelling gets a front door at ground level and the party wall gets nothing" do
    set = pair
    walls = set.surfaces.select { |s| s.kind == :wall }
    fronts = [ walls[0], walls[4] ]
    fronts.each { |front| assert front.patches.any? { |p| p.material == :timber }, "no door" }
    assert_empty walls[12].patches
  end

  test "the roof is one continuous ridge cut at the party line" do
    planes = pair.surfaces.select { |s| s.kind == :roof }

    assert_equal 4, planes.length
    assert_equal [ 6, 6, 6, 6 ], planes.map(&:cols), "each section spans its dwelling plus the end overhang"
    assert_in_delta planes[0].origin.y, planes[2].origin.y, 1e-9, "the same eaves"
    assert_equal planes[0].v, planes[2].v, "the same pitch"
  end

  test "every cell round trips through its index" do
    set = pair
    set.surfaces.each do |surface|
      surface.rows.times do |row|
        surface.cols.times do |col|
          found, r, c = set.at(surface.piece_index(row, col))
          assert_equal [ surface.piece_offset, row, col ], [ found.piece_offset, r, c ]
        end
      end
    end
  end

  # Rotation is a picture, the indices are the contract.
  test "a rotated row has the same pieces at turned positions" do
    flat = pair
    turned = pair("yaw" => Math::PI / 2)

    assert_equal flat.piece_count, turned.piece_count
    assert_equal flat.surfaces.map(&:piece_offset), turned.surfaces.map(&:piece_offset)
    flat.surfaces.zip(turned.surfaces).each do |a, b|
      assert_equal a.rows.times.map { |r| a.cols.times.map { |c| a.material_at(r, c).name } },
                   b.rows.times.map { |r| b.cols.times.map { |c| b.material_at(r, c).name } }
    end
    front = turned.surfaces.first
    assert_in_delta 0.0, front.u.x, 1e-9
    assert_in_delta 1.0, front.u.z, 1e-9
  end

  test "a flat roof is one deck per dwelling" do
    set = pair("roof" => "flat", "ridge" => 6.0)

    assert_equal 2, set.surfaces.count { |s| s.kind == :roof }
    assert_empty set.surfaces.select { |s| s.kind == :gable }
  end

  test "the building kind still goes the old way" do
    house = Game::Building::Generator.call(
      footprint: [ [ 0, 0 ], [ 12, 0 ], [ 12, 15 ], [ 0, 15 ] ],
      storeys: 3, storey_height: 3.0, eaves: 9.0, ridge: 12.75, roof: "gable", cell: 1.0, seed: 7
    )
    assert_equal 1553, house.piece_count
  end

  test "a row is validated" do
    assert_raises(Game::Building::Row::Invalid) { pair("dwellings" => [ { "x0" => 6.0, "x1" => 0.0 } ]) }
    assert_raises(Game::Building::Row::Invalid) { pair("band" => [ 9.0, 0.0 ]) }
    assert_raises(Game::Building::Row::Invalid) { pair("roof" => "thatch") }
  end
end
