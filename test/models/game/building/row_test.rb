require "test_helper"

class Game::Building::RowTest < ActiveSupport::TestCase
  # Two dwellings of 6 x 9 m, two storeys of 3 m, one gable, 1 m cells, no boxes. Chosen so
  # every count can be worked by hand: a 6 m wall is 6 x 3 = 18 cells, a 9 m one 27, a deck
  # 54, a partition across the 6 m width 18, a roof section 6.4 x 5.15 -> 6 x 5 = 30, a
  # gable end 9 x 3 = 27, and the rubble grid ceil(18/2) x ceil(15/2) = 9 x 8 = 72.
  def pair_recipe(**overrides)
    {
      "kind" => "row", "category" => "house", "pands" => %w[000001 000002],
      "yaw" => 0.0, "cell" => 1.0, "seed" => 1,
      "band" => [ 0.0, 9.0 ], "storeys" => 2, "storey_height" => 3.0, "eaves" => 6.0, "ridge" => 8.5, "roof" => "gable",
      "dwellings" => [ { "x0" => 0.0, "x1" => 6.0 }, { "x0" => 6.0, "x1" => 12.0 } ],
      "boxes" => [],
      "footprint" => [ [ 0, 0 ], [ 12, 0 ], [ 12, 9 ], [ 0, 9 ] ]
    }.merge(overrides)
  end

  def pair(**overrides)
    Game::Building::Generator.call(pair_recipe(**overrides))
  end

  # The same row with a dwelling in the middle, which is the only place an end-only rule
  # can be seen to be end-only.
  def terrace(**overrides)
    pair(**{
      "dwellings" => [ { "x0" => 0.0, "x1" => 6.0 }, { "x0" => 6.0, "x1" => 12.0 }, { "x0" => 12.0, "x1" => 18.0 } ],
      "footprint" => [ [ 0, 0 ], [ 18, 0 ], [ 18, 9 ], [ 0, 9 ] ]
    }.merge(overrides))
  end

  # A rear extension against the second dwelling: 3 x 6 m, one storey of 2.8 m, flat.
  def annex(**overrides)
    { "ring" => [ [ 6.0, 9.0 ], [ 9.0, 9.0 ], [ 9.0, 15.0 ], [ 6.0, 15.0 ] ], "eaves" => 2.8, "ridge" => 2.8,
      "storeys" => 1, "roof" => "flat", "door" => false, "solid" => false, "bay" => 1, "name" => "annex" }.merge(overrides)
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

  # THE OTHER HALF OF THE CONTRACT: step 6, which the example above has nothing of. A box is
  # built as its kept walls per storey, then a deck per storey, then its roof -- and that
  # order decides every index after the dwellings, which for a church is every index it has.
  #
  # Worked by hand from the annex: 3 x 6 m, one storey of 2.8 m (so three 1 m rows, rounded),
  # flat, standing against the row's back wall at z = 9.
  #   - its four edges run [6,9]->[9,9], [9,9]->[9,15], [9,15]->[6,15], [6,15]->[6,9]. The
  #     first lies along the row's back wall, which is already walled to 2 x 3 = 6 m, so it
  #     is dropped. The other three are 6, 3 and 6 m long: 6 x 3 = 18, 3 x 3 = 9, 6 x 3 = 18.
  #   - one deck per storey over the ring's own 3 x 6 box: 3 x 6 = 18.
  #   - a flat roof is one more deck of the same 18.
  # 45 + 18 + 18 = 81 cells in five surfaces, appended after the last gable ends at
  # 741 + 27 = 768 and before the rubble -- which moves from 768 to 849, taking the count
  # from 840 to 921. The rubble grid itself does not move: it is laid over the ROW's
  # footprint, which an annex reaching past it does not grow.
  test "a box is walls, then decks, then its roof, and it lands between the roof and the rubble" do
    set = pair("boxes" => [ annex ])

    assert_equal 34, set.surfaces.length
    assert_equal 921, set.piece_count
    assert_equal %i[wall] * 14 + %i[floor floor partition partition floor floor partition partition
                                    roof roof gable roof roof gable wall wall wall floor roof rubble],
                 set.surfaces.map(&:kind)
    assert_equal [ 0, 18, 36, 54, 72, 90, 108, 126, 144, 171, 198, 225, 252, 279,
                   306, 360, 414, 432, 450, 504, 558, 576, 594, 624, 654, 681, 711, 741,
                   768, 786, 795, 813, 831, 849 ],
                 set.surfaces.map(&:piece_offset)
    assert_equal [ 1 ] * 5, set.surfaces[28, 5].map(&:bay), "every surface of the box carries the box's own bay"
  end

  test "every surface knows its bay, and the party wall is shared" do
    set = pair
    walls = set.surfaces.select { |s| s.kind == :wall }

    assert_equal [ 0 ] * 4 + [ 1 ] * 4, walls.first(8).map(&:bay), "front and back walls per dwelling"
    assert_equal [ 1, 1, 0, 0 ], walls[8, 4].map(&:bay), "the right end belongs to the last dwelling, the left to the first"
    assert_equal [ [ 0, 1 ], [ 0, 1 ] ], walls[12, 2].map(&:between), "party walls, one per storey"
    assert_equal [ 0, 1 ], set.bays
    # A dwelling's decks and partitions are built from a Recipe that knows nothing about
    # the row, so the tag put on them afterwards is the only thing that makes them its
    # own -- and an untagged floor would be felled by the neighbour's collapse.
    assert_equal [ 0 ] * 4 + [ 1 ] * 4,
                 set.surfaces.select { |s| %i[floor partition].include?(s.kind) }.map(&:bay),
                 "each dwelling's floors and partitions"
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

  # A three-metre door is a garage. A dwelling's front is a one-cell door with a two-cell
  # window beside it, a pier between; upstairs the windows come in runs of one or two
  # cells, asserted in full by "upstairs windows come in runs..." below.
  test "a dwelling's front is a one-cell door with a two-cell window beside it, and no lintel" do
    set = pair
    walls = set.surfaces.select { |s| s.kind == :wall }
    fronts = [ walls[0], walls[4] ]

    fronts.each do |front|
      doors = front.patches.select { |p| p.material == :door }
      windows = front.patches.select { |p| p.material == :glass }
      assert_equal 1, doors.length, "one door"
      door = doors.first
      assert_equal door.col0, door.col1, "a door is one cell wide"
      assert_equal [ 0, 1 ], [ door.row0, door.row1 ], "a door is two rows tall and stands on the ground"
      assert_equal 1, windows.length, "one window on the ground floor of the front"
      window = windows.first
      assert_equal 2, window.col1 - window.col0 + 1, "the front window is two cells wide"
      assert_equal 1, window.row0, "a window sits on a course, not on the floor"
      assert_includes [ window.col0 - door.col1, door.col0 - window.col1 ], 2, "one pier stands between the door and the window"
      assert front.patches.none? { |p| p.material == :steel }, "no lintel over a one-cell door"
      assert front.patches.none? { |p| p.material == :timber }, "the door is a door, not timber"
    end
    upstairs = walls[1]
    assert upstairs.patches.all? { |p| p.material == :glass && (p.col1 - p.col0).between?(0, 1) }, "upstairs windows are glass, one or two cells"
    assert_empty walls[12].patches, "the party wall gets nothing"
  end

  test "the path columns are the door's" do
    openings = Game::Building::Openings.new(seed: 1, style: :house)
    door = openings.for_wall(edge: 0, storey: 0, cols: 6, rows: 3).find { |p| p.material == :door }

    assert_equal [ door.col0 ], openings.door_columns(6)
    assert_equal [], openings.door_columns(2), "a face too narrow for a door has no path either"
    assert_equal [], Game::Building::Openings.new(seed: 1, style: :annex).door_columns(6)
  end

  # Two rows tall across the face, half a metre in from either side -- or the whole face
  # when the face is under five cells, because a one-cell door on a three-metre garage is
  # a letterbox.
  test "a garage box gets a garage door on its first edge" do
    garage = { "ring" => [ [ 13.0, 0.0 ], [ 19.0, 0.0 ], [ 19.0, 6.0 ], [ 13.0, 6.0 ] ], "eaves" => 2.6, "ridge" => 2.6,
               "storeys" => 1, "roof" => "flat", "door" => "garage", "solid" => false, "bay" => 1, "name" => "garage" }
    set = pair("boxes" => [ garage ], "footprint" => [ [ 0, 0 ], [ 19, 0 ], [ 19, 9 ], [ 0, 9 ] ])
    front = set.surfaces.select { |s| s.kind == :wall }.find { |s| s.origin.x == 13.0 && s.origin.z == 0.0 }

    assert front, "the garage's front wall was not built"
    assert_equal 6, front.cols
    door = front.patches.find { |p| p.material == :door }
    assert door, "no garage door"
    assert_equal [ 1, 4 ], [ door.col0, door.col1 ], "a metre in from either side"
    assert_equal [ 0, 1 ], [ door.row0, door.row1 ], "two rows tall"
    assert front.patches.none? { |p| p.material == :glass }, "a garage front has no windows"

    narrow = pair("boxes" => [ garage.merge("ring" => [ [ 13.0, 0.0 ], [ 16.0, 0.0 ], [ 16.0, 6.0 ], [ 13.0, 6.0 ] ]) ],
                  "footprint" => [ [ 0, 0 ], [ 16, 0 ], [ 16, 9 ], [ 0, 9 ] ])
    small = narrow.surfaces.select { |s| s.kind == :wall }.find { |s| s.origin.x == 13.0 && s.origin.z == 0.0 }
    assert_equal [ 0, 2 ], [ small.patches.find { |p| p.material == :door }.col0, small.patches.find { |p| p.material == :door }.col1 ],
                 "a three-metre garage is all door"
  end

  # A church in miniature: a nave with a two-cell door and tall windows every third column,
  # a tower with one small window per storey, a chapel with windows every other column.
  def church(**overrides)
    nave = { "ring" => [ [ 0, 0 ], [ 24, 0 ], [ 24, 12 ], [ 0, 12 ] ], "eaves" => 10.0, "ridge" => 14.0, "storeys" => 2,
             "roof" => "gable", "door" => true, "solid" => false, "bay" => 0, "name" => "nave" }
    tower = { "ring" => [ [ 30, 2 ], [ 36, 2 ], [ 36, 8 ], [ 30, 8 ] ], "eaves" => 20.0, "ridge" => 27.0, "storeys" => 5,
              "roof" => "pyramid", "door" => false, "solid" => false, "bay" => 1, "name" => "tower" }
    chapel = { "ring" => [ [ 0, 14 ], [ 12, 14 ], [ 12, 20 ], [ 0, 20 ] ], "eaves" => 5.0, "ridge" => 7.0, "storeys" => 1,
               "roof" => "gable", "door" => false, "solid" => false, "bay" => 2, "name" => "chapel" }
    Game::Building::Generator.call(pair_recipe(**{
      "category" => "church", "cell" => 2.0, "dwellings" => [], "boxes" => [ nave, tower, chapel ],
      "band" => [ 0.0, 0.0 ], "storeys" => 5, "storey_height" => 4.0, "eaves" => 20.0, "ridge" => 20.0, "roof" => "flat",
      "footprint" => [ [ 0, 0 ], [ 36, 0 ], [ 36, 20 ], [ 0, 20 ] ]
    }.merge(overrides)))
  end

  test "a church's parts are punctured by what they are" do
    set = church
    walls = set.surfaces.select { |s| s.kind == :wall }
    nave_front = walls.find { |w| w.storey.zero? && w.origin.x == 0.0 && w.origin.z == 0.0 && w.u.x > 0 }
    tower_walls = walls.select { |w| w.origin.x >= 30.0 && w.origin.z >= 2.0 && w.origin.x <= 36.0 && w.origin.z <= 8.0 }
    chapel_walls = walls.select { |w| w.origin.z >= 14.0 }

    assert nave_front, "no nave front"
    door = nave_front.patches.find { |p| p.material == :door }
    assert door, "the nave has no door"
    assert_equal 2, door.col1 - door.col0 + 1, "a church door is two cells wide"
    nave_windows = nave_front.patches.select { |p| p.material == :glass }
    assert_operator nave_windows.length, :>=, 2
    # Every third column, less the one the door displaced: the columns all lie on one
    # rhythm of three, even where a window is missing from it.
    assert nave_windows.all? { |w| (w.col0 - nave_windows.first.col0) % 3 == 0 }, "nave windows every third column: #{nave_windows.map(&:col0)}"

    per_storey = tower_walls.group_by(&:storey).transform_values { |ws| ws.sum { |w| w.patches.count { |p| p.material == :glass } } }
    assert per_storey.values.all? { |n| n.between?(1, 4) }, "a tower has a window or so per storey per face, not a wall of them: #{per_storey}"
    assert tower_walls.none? { |w| w.patches.any? { |p| p.material == :door } }, "no door on the tower"

    chapel_front = chapel_walls.find { |w| w.storey.zero? }
    chapel_windows = chapel_front.patches.select { |p| p.material == :glass }
    assert chapel_windows.each_cons(2).all? { |a, b| b.col0 - a.col0 == 2 }, "chapel windows every other column"
  end

  test "a box door is true, false or a garage" do
    assert_raises(Game::Building::Row::Invalid) { pair("boxes" => [ annex("door" => "hatch") ]) }
    assert_equal "garage", Game::Building::Row.from(pair_recipe("boxes" => [ annex("door" => "garage") ])).boxes.first.door
  end

  test "the roof is one continuous ridge cut at the party line" do
    planes = pair.surfaces.select { |s| s.kind == :roof }

    assert_equal 4, planes.length
    # Not the column count: Walls.cells rounds, so 6.0 and 6.4 both come out as 6 columns
    # and an overhang that had gone missing would still pass. The metres are what say it
    # is there.
    assert_equal [ 6.4 ] * 4, planes.map(&:width), "each section spans its dwelling plus the end overhang"
    assert_equal [ -0.4, -0.4, 6.0, 6.0 ], planes.map { |p| p.origin.x },
                 "the first section starts an overhang back, the second flush against it"
    assert_in_delta planes[0].origin.y, planes[2].origin.y, 1e-9, "the same eaves"
    assert_equal planes[0].v, planes[2].v, "the same pitch"
  end

  # The other half of the overhang rule, which two dwellings cannot show: with every
  # dwelling either first or last, a section that wrongly overhung in the middle would
  # look exactly like one that rightly overhangs at the end.
  test "only the ends of a row overhang, and only they are closed off" do
    set = terrace
    planes = set.surfaces.select { |s| s.kind == :roof }

    assert_equal [ 6.4, 6.4, 6.0, 6.0, 6.4, 6.4 ], planes.map(&:width),
                 "the middle section spans exactly its dwelling and meets its neighbours flush"
    assert_equal [ -0.4, -0.4, 6.0, 6.0, 12.0, 12.0 ], planes.map { |p| p.origin.x }
    assert_equal 2, set.surfaces.count { |s| s.kind == :gable }, "a middle dwelling closes nothing off"
    assert_equal [ 0, 2 ], set.surfaces.select { |s| s.kind == :gable }.map(&:bay)
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

  test "a box against the row generates no wall where it stands against it" do
    set = pair("boxes" => [ annex ])
    box_walls = set.surfaces.select { |s| s.kind == :wall && s.height == 2.8 }

    assert_equal 3, box_walls.length, "four edges, one of them along the row's back wall"
    assert box_walls.none? { |w| w.origin.z == 9.0 && w.u.z.zero? }, "the junction edge was generated"
    assert_equal [ 1 ] * 3, box_walls.map(&:bay)
  end

  test "a box's decks are void where they would lie inside the row" do
    set = pair("boxes" => [ annex("ring" => [ [ 6.0, 7.0 ], [ 9.0, 7.0 ], [ 9.0, 15.0 ], [ 6.0, 15.0 ] ]) ])
    deck = set.surfaces.select { |s| s.kind == :floor && s.bay == 1 }.last

    assert_equal :void, deck.material_at(0, 0).name, "the two metres inside the row"
    assert_equal :concrete, deck.material_at(deck.rows - 1, 0).name
  end

  test "two boxes that meet share one wall" do
    twin = annex("ring" => [ [ 9.0, 9.0 ], [ 12.0, 9.0 ], [ 12.0, 15.0 ], [ 9.0, 15.0 ] ], "name" => "twin")
    set = pair("boxes" => [ annex, twin ])
    box_walls = set.surfaces.select { |s| s.kind == :wall && s.height == 2.8 }

    assert_equal 5, box_walls.length, "3 + 3 minus the wall they share"
  end

  # The other half of the sharing rule, and the one the church needs: what stands against a
  # wall excuses the storeys BEHIND it and no more. Taking the decision once for the box
  # leaves a six-storey tower open above the two-storey nave it is attached to.
  test "a taller box keeps the storeys of a shared wall that stand above its neighbour" do
    low = { "ring" => [ [ 0, 0 ], [ 4, 0 ], [ 4, 6 ], [ 0, 6 ] ], "eaves" => 2.8, "ridge" => 2.8, "storeys" => 1, "roof" => "flat", "solid" => true, "bay" => 0 }
    tall = low.merge("ring" => [ [ 4, 0 ], [ 8, 0 ], [ 8, 6 ], [ 4, 6 ] ], "eaves" => 5.6, "ridge" => 5.6, "storeys" => 2, "bay" => 1)
    set = pair("dwellings" => [], "boxes" => [ low, tall ], "footprint" => [ [ 0, 0 ], [ 8, 0 ], [ 8, 6 ], [ 0, 6 ] ], "storeys" => 2)
    walls = set.surfaces.select { |s| s.kind == :wall }
    shared = walls.select { |w| w.origin.x == 4.0 && w.u.x.zero? }

    assert_equal 2, shared.length, "the low box walls the ground floor and the tall one the storey above it"
    assert_equal [ [ 0, 0.0, 0 ], [ 1, 2.8, 1 ] ], shared.map { |w| [ w.storey, w.origin.y, w.bay ] }
    assert_equal [ 2.8 ] * 2, shared.map(&:height), "neither of them is a wall and a half"
    assert_equal 4, walls.count { |w| w.bay.zero? }, "the low box: four edges of one storey"
    assert_equal 7, walls.count { |w| w.bay == 1 }, "the tall box: three free edges of two storeys, plus the storey above its neighbour"
  end

  test "a box against a lower row keeps the storeys that stand above it" do
    set = pair("storeys" => 1, "eaves" => 3.0, "ridge" => 5.5, "boxes" => [ annex("eaves" => 5.6, "ridge" => 5.6, "storeys" => 2) ])
    junction = set.surfaces.select { |s| s.kind == :wall && s.height == 2.8 && s.origin.z == 9.0 && s.u.z.zero? }

    assert_equal 1, junction.length, "only the storey behind the row's own wall is dropped"
    assert_equal [ 1, 2.8 ], [ junction.first.storey, junction.first.origin.y ]
  end

  test "a row of boxes only is legal, and every box is its own bay" do
    shed = { "ring" => [ [ 0, 0 ], [ 2.2, 0 ], [ 2.2, 3.2 ], [ 0, 3.2 ] ], "eaves" => 2.5, "ridge" => 2.5, "storeys" => 1, "roof" => "flat", "solid" => true, "bay" => 0 }
    twin = shed.merge("ring" => [ [ 2.2, 0 ], [ 4.4, 0 ], [ 4.4, 3.2 ], [ 2.2, 3.2 ] ], "bay" => 1)
    set = pair("dwellings" => [], "boxes" => [ shed, twin ], "footprint" => [ [ 0, 0 ], [ 4.4, 0 ], [ 4.4, 3.2 ], [ 0, 3.2 ] ], "storeys" => 1)

    assert_equal [ 0, 1 ], set.bays
    assert set.surfaces.select { |s| s.kind == :wall }.all? { |w| w.patches.empty? }, "a solid box has no openings"
    assert_equal :rubble, set.surfaces.last.kind
  end

  test "a pyramid roof is four triangles meeting at one apex" do
    tower = { "ring" => [ [ 0, 0 ], [ 8, 0 ], [ 8, 8 ], [ 0, 8 ] ], "eaves" => 24.0, "ridge" => 30.0, "storeys" => 6, "roof" => "pyramid", "bay" => 0 }
    set = pair("dwellings" => [], "boxes" => [ tower ], "footprint" => tower["ring"], "storeys" => 6)
    planes = set.surfaces.select { |s| s.kind == :roof }

    assert_equal 4, planes.length
    planes.each do |plane|
      assert_in_delta 24.0, plane.origin.y, 1e-9
      assert plane.patches.any? { |p| p.material == :void }, "the corners above the pitch should be void"
      assert_equal :roof_tile, plane.material_at(plane.rows - 1, plane.cols / 2).name, "the apex column stays"
    end
  end

  test "a gable box roofs over its own box" do
    chapel = { "ring" => [ [ 0, 0 ], [ 6, 0 ], [ 6, 10 ], [ 0, 10 ] ], "eaves" => 4.0, "ridge" => 7.0, "storeys" => 1, "roof" => "gable", "bay" => 0 }
    set = pair("dwellings" => [], "boxes" => [ chapel ], "footprint" => chapel["ring"], "storeys" => 1)

    assert_equal 2, set.surfaces.count { |s| s.kind == :roof }
    assert_equal 2, set.surfaces.count { |s| s.kind == :gable }
  end

  test "a door face under three columns gets no door" do
    shed = { "ring" => [ [ 0, 0 ], [ 2.2, 0 ], [ 2.2, 3.2 ], [ 0, 3.2 ] ], "eaves" => 2.5, "ridge" => 2.5, "storeys" => 1, "roof" => "flat", "door" => true, "bay" => 0 }
    set = pair("dwellings" => [], "boxes" => [ shed ], "footprint" => shed["ring"], "storeys" => 1)
    front = set.surfaces.find { |s| s.kind == :wall }

    assert_equal 2, front.cols
    assert front.patches.none? { |p| %i[timber steel].include?(p.material) }, "a two-cell face was all door and lintel"
  end

  test "the building kind still goes the old way" do
    house = Game::Building::Generator.call(
      footprint: [ [ 0, 0 ], [ 12, 0 ], [ 12, 15 ], [ 0, 15 ] ],
      storeys: 3, storey_height: 3.0, eaves: 9.0, ridge: 12.75, roof: "gable", cell: 1.0, seed: 7
    )
    assert_equal 1553, house.piece_count
  end

  test "a row carries a palette the table knows" do
    assert_equal "brown_brick", Game::Building::Row.from(pair_recipe).palette
    assert_equal "red_brick", Game::Building::Row.from(pair_recipe("palette" => "red_brick")).palette
    assert_raises(Game::Building::Row::Invalid) { Game::Building::Row.from(pair_recipe("palette" => "tartan")) }
  end

  test "a row is validated" do
    assert_raises(Game::Building::Row::Invalid) { pair("dwellings" => [ { "x0" => 6.0, "x1" => 0.0 } ]) }
    # Overlapping and gaping are the same mistake seen from either side, and only the
    # first of them used to be caught.
    assert_raises(Game::Building::Row::Invalid) { pair("dwellings" => [ { "x0" => 0.0, "x1" => 6.0 }, { "x0" => 3.0, "x1" => 9.0 } ]) }
    assert_raises(Game::Building::Row::Invalid) { pair("dwellings" => [ { "x0" => 0.0, "x1" => 6.0 }, { "x0" => 10.0, "x1" => 16.0 } ]) }
    # Half a metre either way is an imported party line, not a hole.
    assert_equal 3, terrace("dwellings" => [ { "x0" => 0.0, "x1" => 6.0 }, { "x0" => 6.4, "x1" => 12.0 }, { "x0" => 11.6, "x1" => 18.0 } ]).bays.length
    assert_raises(Game::Building::Row::Invalid) { pair("band" => [ 9.0, 0.0 ]) }
    assert_raises(Game::Building::Row::Invalid) { pair("roof" => "thatch") }
    # Nothing here is a small building. A zero height is a surface with no extent: no rows
    # of cells, a collider of no thickness, and a gable end that is a triangle of nothing.
    assert_raises(Game::Building::Row::Invalid) { pair("eaves" => 0.0, "ridge" => 0.0) }
    assert_raises(Game::Building::Row::Invalid) { pair("storey_height" => 0.0) }
    assert_raises(Game::Building::Row::Invalid) { pair("ridge" => 6.0) }
    assert_raises(Game::Building::Row::Invalid) { pair("boxes" => [ annex("eaves" => 0.0, "ridge" => 0.0) ]) }
    assert_raises(Game::Building::Row::Invalid) { pair("boxes" => [ annex("roof" => "gable") ]) }
  end

  def gardened(**overrides)
    pair(**{ "gardens" => [ { "bay" => 0, "depth" => 5.0 }, { "bay" => 1, "depth" => 5.0 } ] }.merge(overrides))
  end

  # STEP 7 OF THE CONTRACT. A hedge is one row of cells per garden, after the boxes and
  # before the rubble, so a row that gains a garden keeps every index it had and the rubble
  # moves back by the hedge -- 6 cells per 6 m dwelling here.
  test "hedges come after the boxes and before the rubble, one per garden" do
    set = gardened

    assert_equal 31, set.surfaces.length
    assert_equal 852, set.piece_count
    assert_equal %i[hedge hedge rubble], set.surfaces.last(3).map(&:kind)
    assert_equal [ 768, 774, 780 ], set.surfaces.last(3).map(&:piece_offset)
    hedges = set.surfaces.select { |s| s.kind == :hedge }
    assert_equal [ 0, 1 ], hedges.map(&:bay)
    assert_equal [ -1, -1 ], hedges.map(&:storey), "a hedge stands outside every storey the collapse rule can reach"
    assert_equal [ 6, 6 ], hedges.map(&:cols)
    assert_equal [ 1, 1 ], hedges.map(&:rows)
    assert_equal :hedge, hedges.first.material.name
    # The front line is z = 0, the road edge 5 m out; the hedge stands KERB in from it,
    # its thickness straddling its plane, on the ground.
    assert_in_delta(-5.0 + 0.4 + 0.25, hedges.first.origin.z, 1e-9)
    assert_in_delta 0.0, hedges.first.origin.y, 1e-9
    assert_equal [ 0.0, 6.0 ], hedges.map { |h| h.origin.x }
  end

  test "a hedge is broken at the garden path, which meets the door" do
    set = gardened
    hedge = set.surfaces.find { |s| s.kind == :hedge }
    front = set.surfaces.first
    door = front.patches.find { |p| p.material == :door }
    void = hedge.patches.select { |p| p.material == :void }.map(&:col0).sort

    assert_equal 2, void.length, "a 1.2 m path is two one-metre cells"
    assert_includes void, door.col0, "the path meets the door"
    assert void.each_cons(2).all? { |a, b| b == a + 1 }, "the path is one gap, not two"
  end

  test "a row with no gardens has no hedges and moves nothing" do
    assert_equal 840, pair.piece_count
    assert_empty pair.surfaces.select { |s| s.kind == :hedge }
    assert_empty Game::Building::RowGenerator.lawns(Game::Building::Row.from(pair_recipe))
  end

  test "the wreckage of a house is not made of leaves" do
    rubble = gardened.surfaces.last

    refute_includes rubble.mix.map(&:first), :hedge
    assert_equal pair.surfaces.last.mix, rubble.mix, "a garden changes nothing about what the house is made of"
    assert_in_delta pair.surfaces.last.thickness, rubble.thickness, 1e-9, "nor how deep its wreckage lies"
  end

  # A garaged front has a DRIVE as well as a path. The hedge is broken in front of the
  # garage door too -- three cells of door with a hedge grown across them is a car walled
  # in -- and the lawn is what is left between the openings.
  test "a garaged dwelling's hedge opens in front of its garage door, and the lawn keeps off" do
    overrides = { "dwellings" => [ { "x0" => 0.0, "x1" => 6.0, "garage" => true }, { "x0" => 6.0, "x1" => 12.0 } ],
                  "gardens" => [ { "bay" => 0, "depth" => 5.0 } ] }
    set = pair(**overrides)
    hedge = set.surfaces.find { |s| s.kind == :hedge }
    void = hedge.patches.select { |p| p.material == :void }.map(&:col0).sort
    doors = set.surfaces.first.patches.select { |p| p.material == :door }.sort_by { |p| p.col1 - p.col0 }
    front_door, garage = doors

    assert_equal 3, garage.col1 - garage.col0 + 1, "the wide one is the garage door"
    assert_empty (garage.col0..garage.col1).to_a - void, "the hedge still stands across the garage door"
    assert_includes void, front_door.col0, "and it still opens at the front door"

    # The lawn is the columns the hedge kept, and nothing else: no rectangle lies over the
    # drive or the path.
    lawns = Game::Building::Gardens.lawns(Game::Building::Row.from(pair_recipe(**overrides)))
    fronts = lawns[0...-1]
    cell = 6.0 / hedge.cols
    assert_in_delta (hedge.cols - void.length) * cell, fronts.sum { |r| r.map(&:first).max - r.map(&:first).min }, 1e-9,
                    "the lawn covers every column the hedge kept and no other"
    void.each do |col|
      assert fronts.none? { |r| r.map(&:first).min < (col + 1) * cell - 1e-9 && r.map(&:first).max > col * cell + 1e-9 },
             "a lawn was laid over column #{col}, which the hedge leaves open"
    end
  end

  # Two rectangles per front garden either side of the path, and one strip behind the row.
  test "lawns are the front garden minus the path, and a strip behind" do
    row = Game::Building::Row.from(pair_recipe("gardens" => [ { "bay" => 0, "depth" => 5.0 }, { "bay" => 1, "depth" => 5.0 } ]))
    lawns = Game::Building::Gardens.lawns(row)

    assert_equal 5, lawns.length
    fronts = lawns.first(4)
    fronts.each do |ring|
      assert_equal 4, ring.length
      assert_equal [ -5.0, 0.0 ], [ ring.map(&:last).min, ring.map(&:last).max ], "a front lawn runs from the road edge to the front line"
    end
    assert_in_delta 12.0 - 2 * 2.0, fronts.sum { |ring| ring.map(&:first).max - ring.map(&:first).min }, 1e-9,
                    "the two paths are the only gaps"
    back = lawns.last
    assert_equal [ 9.0, 14.0 ], [ back.map(&:last).min, back.map(&:last).max ], "five metres behind the footprint"
    assert_equal [ 0.0, 12.0 ], [ back.map(&:first).min, back.map(&:first).max ]
  end

  test "lawns turn with the row" do
    recipe = pair_recipe("yaw" => Math::PI / 2, "gardens" => [ { "bay" => 0, "depth" => 5.0 } ])
    flat = Game::Building::Gardens.lawns(Game::Building::Row.from(recipe.merge("yaw" => 0.0)))
    turned = Game::Building::RowGenerator.lawns(Game::Building::Row.from(recipe))

    assert_equal flat.length, turned.length
    fx, fz = flat.first.first
    tx, tz = turned.first.first
    assert_in_delta(-fz, tx, 1e-9)
    assert_in_delta fx, tz, 1e-9
    assert_equal turned, Game::Building::Generator.lawns(recipe)
    assert_empty Game::Building::Generator.lawns(footprint: [ [ 0, 0 ], [ 12, 0 ], [ 12, 15 ], [ 0, 15 ] ], storeys: 2, cell: 1.0, seed: 7)
  end

  test "a garden must front a dwelling and reach the road" do
    assert_raises(Game::Building::Row::Invalid) { pair("gardens" => [ { "bay" => 2, "depth" => 5.0 } ]) }
    assert_raises(Game::Building::Row::Invalid) { pair("gardens" => [ { "bay" => 0, "depth" => 0.0 } ]) }
  end

  # A wall of identical one-cell windows every other column reads as wallpaper. Upstairs
  # and at the back the windows now come in runs of one or two cells, one pier between,
  # never touching the last column.
  test "upstairs windows come in runs of one or two cells with one pier between" do
    set = pair
    walls = set.surfaces.select { |s| s.kind == :wall }
    [ walls[1], walls[3], walls[5], walls[7] ].each do |wall|
      runs = wall.patches.select { |p| p.material == :glass }.sort_by(&:col0)
      assert_operator runs.length, :>=, 1, "no windows on a #{wall.cols}-column face"
      runs.each do |run|
        assert_includes [ 1, 2 ], run.col1 - run.col0 + 1, "a window is one or two cells"
        assert_equal 1, run.row0, "a window sits on a course"
        assert_operator run.col0, :>=, 1, "a window never touches the first column"
        assert_operator run.col1, :<=, wall.cols - 2, "a window never touches the last column"
      end
      runs.each_cons(2) { |a, b| assert_equal 2, b.col0 - a.col1, "exactly one pier between windows" }
    end
    # Six metres of front at one-metre cells has room for a two and a one, and the seed
    # gives this one both.
    widths = walls[1].patches.map { |p| p.col1 - p.col0 + 1 }
    assert_equal 2, widths.uniq.length, "a run of only one width is the old rhythm in disguise: #{widths}"
  end

  # A MIX, not a second fixed rhythm. `draw`'s low bit used to flip on every run, so a face
  # went 2, 1, 2, 1 as reliably as the every-other-column rhythm the runs replaced -- and a
  # strict alternation never puts two runs of the same width side by side. Over forty seeds
  # of the pair's front upstairs face, a good few should.
  test "the run widths are mixed rather than alternating" do
    faces = (1..40).map do |seed|
      wall = pair("seed" => seed).surfaces.select { |s| s.kind == :wall }[1]
      wall.patches.select { |p| p.material == :glass }.sort_by(&:col0).map { |p| p.col1 - p.col0 + 1 }
    end
    same = faces.count { |widths| widths.each_cons(2).any? { |a, b| a == b } }

    assert_operator same, :>=, faces.length / 4,
                    "only #{same} of #{faces.length} faces put two runs of the same width side by side, " \
                    "which is what a strict 2, 1, 2, 1 rhythm looks like"
  end

  # The estate builds its garage INTO the house, under the first floor, with the door in
  # the front wall. A flagged dwelling's front is: the door near one end, one pier, a
  # garage door three cells wide and two rows tall, and no front window.
  test "a dwelling with a garage has its door in the front wall and no front window" do
    set = pair("dwellings" => [ { "x0" => 0.0, "x1" => 6.0, "garage" => true }, { "x0" => 6.0, "x1" => 12.0 } ])
    front = set.surfaces.first
    doors = front.patches.select { |p| p.material == :door }.sort_by(&:col0)

    assert_equal 2, doors.length, "a front door and a garage door"
    assert_empty front.patches.select { |p| p.material == :glass }, "a garage takes the front window's place"
    garage, door = doors.first.col1 - doors.first.col0 == 2 ? [ doors.first, doors.last ] : [ doors.last, doors.first ]
    assert_equal 3, garage.col1 - garage.col0 + 1, "a garage door is three cells wide"
    assert_equal [ 0, 1 ], [ garage.row0, garage.row1 ], "two rows tall, on the ground"
    assert_equal door.col0, door.col1, "the front door is still one cell"
    assert_equal 2, [ (garage.col0 - door.col1).abs, (door.col0 - garage.col1).abs ].min, "one pier between them"
    # The second dwelling is unflagged and keeps its two-cell window.
    second = set.surfaces.select { |s| s.kind == :wall }[4]
    assert_equal 1, second.patches.count { |p| p.material == :glass }
  end

  test "a garage needs six columns" do
    set = pair("dwellings" => [ { "x0" => 0.0, "x1" => 5.0, "garage" => true }, { "x0" => 5.0, "x1" => 12.0 } ])
    front = set.surfaces.first
    assert_equal 5, front.cols
    assert_equal 1, front.patches.count { |p| p.material == :door }, "a five-cell front has no room for a garage"
    assert_equal 1, front.patches.count { |p| p.material == :glass }, "so it keeps its window"
  end

  # Glass from floor to ceiling on the ground floor of the back, and nothing else there.
  test "a glazed dwelling has one glass wall at the back, floor to ceiling" do
    set = pair("dwellings" => [ { "x0" => 0.0, "x1" => 6.0 }, { "x0" => 6.0, "x1" => 12.0, "glazing" => true } ])
    walls = set.surfaces.select { |s| s.kind == :wall }
    # The back of dwelling 1: walls are fronts then backs per dwelling, two storeys each,
    # so dwelling 1's ground-floor back is the seventh wall. It runs west from x = 12.
    back = walls[6]
    assert_in_delta 12.0, back.origin.x, 1e-9
    glass = back.patches.select { |p| p.material == :glass }

    assert_equal 1, glass.length, "one glass patch"
    assert_equal 3, glass.first.col1 - glass.first.col0 + 1, "three cells wide on a six-column face"
    assert_equal [ 0, back.rows - 1 ], [ glass.first.row0, glass.first.row1 ], "floor to ceiling"
    assert_operator glass.first.col0, :>=, 1
    assert_operator glass.first.col1, :<=, back.cols - 2
    assert_equal glass, back.patches, "nothing else on that face"
    # Upstairs at the back is unchanged: runs.
    assert_operator walls[7].patches.count { |p| p.material == :glass }, :>=, 1
    # The unflagged neighbour's back keeps its runs.
    assert_operator walls[2].patches.count { |p| p.material == :glass }, :>=, 1
  end

  # "Glass floor to ceiling, a pier kept at each end" needs four columns: two for the
  # glass, one for each pier. A 3 m dwelling at 1 m cells is a 3-column back, too narrow
  # for that pier at the far end, so it gets no glazing at all.
  test "a glazed dwelling too narrow for a pier at each end gets no glazing" do
    set = pair("dwellings" => [ { "x0" => 0.0, "x1" => 3.0, "glazing" => true }, { "x0" => 3.0, "x1" => 12.0 } ])
    back = set.surfaces.select { |s| s.kind == :wall }[2]

    assert_equal 3, back.cols, "a 3 m dwelling at 1 m cells is a 3-column back wall"
    assert back.patches.none? { |p| p.row1 == back.rows - 1 && p.row0 == 0 },
           "no floor-to-ceiling glazing on a face too narrow to keep a pier at each end"
    # At this seed a plain 3-column face draws no run either -- a run has to start at
    # column 1 or 2 and end by cols - 2 = 1, and this face's seed starts it at 2, so there
    # is nothing left to assert beyond the invariant above: the face is bare, not proven
    # to keep a window.
  end

  # The one style the hand-made worlds are built from does not move.
  test "the classic rhythm is what it always was" do
    patches = Game::Building::Openings.new(seed: 7).for_wall(edge: 0, storey: 1, cols: 12, rows: 3)
    assert_equal [ 1, 3, 5, 7, 9, 11 ], patches.map(&:col0)
    assert patches.all? { |p| p.col0 == p.col1 && p.row0 == 1 && p.material == :glass }
  end

  test "the flags parse and are booleans" do
    row = Game::Building::Row.from(pair_recipe("dwellings" => [ { "x0" => 0.0, "x1" => 6.0, "garage" => true, "dormer" => true }, { "x0" => 6.0, "x1" => 12.0, "glazing" => true } ]))
    assert row.dwellings[0].garage
    assert row.dwellings[0].dormer
    refute row.dwellings[0].glazing
    assert row.dwellings[1].glazing
    refute row.dwellings[1].garage
    assert_raises(Game::Building::Row::Invalid) { pair("dwellings" => [ { "x0" => 0.0, "x1" => 6.0, "garage" => "yes" }, { "x0" => 6.0, "x1" => 12.0 } ]) }
  end

  # STEP 5b OF THE CONTRACT. A dormer is four surfaces generated right after its dwelling's
  # roof section: the front, the two cheeks, the top. Worked by hand from the pair with a
  # dormer on the first dwelling: depth 9 so the run is 4.5, rise 2.5; width min(3, 6 - 2)
  # = 3; the top runs back 1.5 x 4.5 / 2.5 = 2.7 m from a setback of 1.0, and 3.7 <= 4.5 -
  # 0.5 leaves room under the ridge. Front 3 x 2 = 6 cells (1.5 m is two rows), cheeks
  # round(2.7) = 3 x 2 = 6 each, top 3 x 3 = 9: 27 cells in four surfaces after the first
  # gable end ends at 681, so the second dwelling's roof starts at 708 rather than 681
  # and the rubble at 795 rather than 768; 840 -> 867 pieces, 29 -> 33 surfaces.
  test "a dormer is four surfaces right after its dwelling's roof section" do
    set = pair("dwellings" => [ { "x0" => 0.0, "x1" => 6.0, "dormer" => true }, { "x0" => 6.0, "x1" => 12.0 } ])

    assert_equal 33, set.surfaces.length
    assert_equal 867, set.piece_count
    assert_equal %i[wall] * 14 + %i[floor floor partition partition floor floor partition partition
                                    roof roof gable wall wall wall roof roof roof gable rubble],
                 set.surfaces.map(&:kind)
    assert_equal [ 0, 18, 36, 54, 72, 90, 108, 126, 144, 171, 198, 225, 252, 279,
                   306, 360, 414, 432, 450, 504, 558, 576, 594, 624, 654, 681,
                   687, 693, 699, 708, 738, 768, 795 ],
                 set.surfaces.map(&:piece_offset)

    front, left, right, top = set.surfaces[25, 4]
    assert_equal [ 2, 2, 2, 2 ], [ front.storey, left.storey, right.storey, top.storey ], "a dormer is above every storey, like a roof"
    assert_equal [ 0 ] * 4, [ front.bay, left.bay, right.bay, top.bay ]
    assert_equal :glass, front.material.name
    assert_equal %i[plaster plaster], front.patches.map(&:material), "a plaster return at each end"
    assert_equal [ 0, 2 ], front.patches.map(&:col0), "the returns are the outer columns"
    assert_in_delta 1.5, front.origin.x, 1e-9, "centred on the six-metre dwelling"
    assert_in_delta 1.0, front.origin.z, 1e-9, "a metre in from the eaves line"
    assert_in_delta 6.0 + 2.5 * 1.0 / 4.5, front.origin.y, 1e-9, "standing on the roof plane"
    assert_equal :plaster, left.material.name
    assert_in_delta 2.7, left.width, 1e-9, "the cheek runs back to where the top meets the roof"
    assert_in_delta 1.5, left.height, 1e-9
    assert_in_delta 4.5, right.origin.x, 1e-9
    assert_equal :steel, top.material.name
    assert_in_delta front.origin.y + 1.5, top.origin.y, 1e-9
    assert_equal [ 3, 3 ], [ top.cols, top.rows ]
    # The top is zinc sheet on boards. At Roof::THICKNESS it was the heaviest thing on the
    # house -- heavier per cell than the tiled roof it stands on, which is what makes a
    # flagged dwelling condemn earlier than its neighbour for the same damage.
    assert_equal Game::Building::RowGenerator::DORMER_TOP_THICKNESS, top.thickness
    plane = set.surfaces.find { |s| s.kind == :roof }
    top_kg = top.to_spec[:kg].fetch("steel")
    plane_kg = plane.to_spec[:kg].fetch("roof_tile")
    assert_operator top_kg, :<, plane_kg,
                    "a zinc deck weighs #{top_kg} kg a cell against the roof plane's #{plane_kg}; at Roof::THICKNESS it was 1404"
  end

  test "a dormer needs a roof with room under the ridge, and an unflagged dwelling gets none" do
    # A shallow roof: rise 1.0 on a 4.5 m run puts the top 6.75 m back, past the ridge, so
    # no dormer is added. The count is 804, not the pair's usual 840, because dropping the
    # ridge to 7.0 also drops the rise to 1.0 and with it each gable's rows from
    # round(2.5) = 3 to round(1.0) = 1 -- 18 fewer cells per gable, two gables, 840 - 36.
    shallow = pair("ridge" => 7.0, "dwellings" => [ { "x0" => 0.0, "x1" => 6.0, "dormer" => true }, { "x0" => 6.0, "x1" => 12.0 } ])
    assert_equal 804, shallow.piece_count, "no room, no dormer"
    assert_equal 804, pair("ridge" => 7.0).piece_count, "the same shallow roof without the flag costs nothing extra"
    assert_equal 840, pair.piece_count
    # A flat roof has nothing to stand a dormer on.
    flat = pair("roof" => "flat", "ridge" => 6.0, "dwellings" => [ { "x0" => 0.0, "x1" => 6.0, "dormer" => true }, { "x0" => 6.0, "x1" => 12.0 } ])
    assert_empty flat.surfaces.select { |s| s.material.name == :steel }
  end

  test "a dormer turns with the row and falls with its bay" do
    flat = pair("dwellings" => [ { "x0" => 0.0, "x1" => 6.0, "dormer" => true }, { "x0" => 6.0, "x1" => 12.0 } ])
    turned = pair("yaw" => Math::PI / 2, "dwellings" => [ { "x0" => 0.0, "x1" => 6.0, "dormer" => true }, { "x0" => 6.0, "x1" => 12.0 } ])
    assert_equal flat.surfaces.map(&:piece_offset), turned.surfaces.map(&:piece_offset), "a rotation is a picture"
    front = turned.surfaces[25]
    assert_equal :glass, front.material.name, "index 25 is the front, not a cheek that happens to share its origin"
    assert_in_delta(-1.0, front.origin.x, 1e-9)
    assert_in_delta 1.5, front.origin.z, 1e-9
    assert_equal [ 0 ], flat.for_bay(0)[:own].select { |s| s.material.name == :steel }.map(&:bay)
    assert_empty flat.for_bay(1)[:own].select { |s| s.material.name == :steel }
  end
end
