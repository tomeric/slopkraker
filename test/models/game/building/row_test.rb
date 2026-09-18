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
  # window beside it, a pier between; upstairs the windows go every other column as before.
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
    assert upstairs.patches.all? { |p| p.material == :glass && p.col0 == p.col1 }, "upstairs windows are one cell"
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
end
