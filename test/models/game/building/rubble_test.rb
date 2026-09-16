require "test_helper"

class Game::Building::RubbleTest < ActiveSupport::TestCase
  # The same house the generator's worked example uses, so the two cannot drift apart.
  def recipe(**overrides)
    Game::Building::Recipe.from({
      footprint: [ [ 0, 0 ], [ 12, 0 ], [ 12, 15 ], [ 0, 15 ] ],
      storeys: 3, storey_height: 3.0, eaves: 9.0, ridge: 12.75,
      roof: "gable", cell: 1.0, seed: 7
    }.merge(overrides))
  end

  def surface(**overrides)
    Game::Building::Generator.call(recipe(**overrides)).surfaces.last
  end

  def heap_volume(set)
    piles = Game::Building::Rubble.total_piles(set)
    spread = Game::Building::Rubble::SPREAD * Game::Building::Rubble::CELL
    piles * spread * spread * set.thickness
  end

  def material_volume(**overrides)
    Game::Building::Generator.call(recipe(**overrides)).surfaces.sum do |s|
      next 0.0 if s.kind == :rubble

      s.rows.times.sum do |row|
        s.cols.times.sum do |col|
          s.material_at(row, col).name == :void ? 0.0 : s.cell_area * s.thickness
        end
      end
    end
  end

  def pile_count(set)
    set.rows.times.sum do |row|
      set.cols.times.count { |col| set.material_at(row, col).name == :rubble }
    end
  end

  test "the grid covers the footprint and a margin round it in coarse cells" do
    set = surface
    margin = Game::Building::Rubble::MARGIN

    assert_equal :rubble, set.kind
    assert_equal 8, set.cols, "12m of footprint plus #{margin}m either side, in 2m cells"
    assert_equal 10, set.rows, "15m of footprint plus #{margin}m either side, rounded up"
    assert_in_delta(-margin, set.origin.x, 1e-9, "the grid starts a margin before the walls")
    assert_in_delta(-margin, set.origin.z, 1e-9)
  end

  # Enough to make the site a job, few enough that the job is a pleasure. Eighty, now that
  # the wreckage skirts the walls: every cell of the grown grid is within reach of a
  # rectangular footprint's edge.
  test "a house leaves roughly eighty piles" do
    assert_in_delta 80, pile_count(surface), 10
  end

  # The whole reason positions agree in multiplayer without a byte on the wire. Every
  # client generates from the same recipe, so the same seed must give the same piles.
  test "piles are deterministic in the seed" do
    same = surface(seed: 7)
    again = surface(seed: 7)

    same.rows.times do |row|
      same.cols.times do |col|
        assert_equal same.material_at(row, col).name, again.material_at(row, col).name
      end
    end
  end

  # Every square of ground the wreckage reaches gets debris on it, whatever the seed. A
  # cell left empty is a hole in the mound by construction, and a hole in a pile of rubble
  # reads as a pocket of air rather than as variety -- the irregularity belongs in the
  # shapes and how they overlap, which is the client's business and still seeded.
  #
  # This replaced a test that the seed changed which cells were occupied. At full density
  # it no longer does, and that is the point rather than a regression.
  test "every square the wreckage reaches holds debris, whatever the seed" do
    [ 7, 8, 99 ].each do |seed|
      set = surface(seed: seed)
      recipe = recipe(seed: seed)

      set.rows.times do |row|
        set.cols.times do |col|
          covered = Game::Building::Rubble.covered?(recipe, row, col)
          held = set.material_at(row, col).name == :rubble

          assert_equal covered, held,
                       "cell #{row},#{col} at seed #{seed} is #{held ? "debris" : "empty"} " \
                       "but #{covered ? "within" : "beyond"} the wreckage's reach"
        end
      end
    end
  end

  # It lies flat rather than standing up like a wall, and it is below every real storey so
  # that no sweep in the collapse rule can reach it. How deep it is is a separate question,
  # answered by what the building was made of -- see below.
  test "the grid lies flat, below every storey" do
    set = surface

    assert_equal(-1, set.storey)
    assert_equal Game::Building::Rubble::EAST, set.u
    assert_equal Game::Building::Rubble::SOUTH, set.v
  end

  # A house gutted to the ground leaves all of it; one that lost only its top floor leaves
  # a third. Reserved for the maximum either way, because piece_count is a property of the
  # recipe and is stored on the row.
  test "how much is revealed scales with how much came down" do
    set = surface
    total = pile_count(set)

    assert_equal total,
                 Game::Building::Rubble.revealed_count(set, storey_count: 3, collapsed_from: 0)
    assert_in_delta total / 3.0,
                    Game::Building::Rubble.revealed_count(set, storey_count: 3, collapsed_from: 2), 1.0
    assert_equal 0,
                 Game::Building::Rubble.revealed_count(set, storey_count: 3, collapsed_from: nil)
  end

  # A building is rarely a rectangle. The wreckage skirts the walls by its margin and no
  # further, so the notch of an L gets a skirt along its two inner edges and nothing in
  # the middle of it -- rubble has no business out on the pavement.
  test "no pile sits further than the margin from the footprint" do
    margin = Game::Building::Rubble::MARGIN
    cell = Game::Building::Rubble::CELL
    l_shaped = surface(footprint: [ [ 0, 0 ], [ 12, 0 ], [ 12, 6 ], [ 6, 6 ], [ 6, 15 ], [ 0, 15 ] ])
    skirted = 0

    l_shaped.rows.times do |row|
      l_shaped.cols.times do |col|
        next unless l_shaped.material_at(row, col).name == :rubble

        x = -margin + (col + 0.5) * cell
        z = -margin + (row + 0.5) * cell
        refute(x > 6 + margin && z > 6 + margin, "a pile landed deep in the notch of the L at #{x}, #{z}")
        skirted += 1 if x > 6 && z > 6
      end
    end

    assert_operator skirted, :>, 0, "the notch's inner edges got no skirt at all"
  end

  # What a house leaves is what a house was MADE of. A three storey house is 353 cubic
  # metres of material and 559 tonnes of it, and heaps sized by a constant would be the
  # same on a bungalow and a tower -- which is the difference between wreckage and a
  # decoration that happens to be lying where a building used to be.
  #
  # Measured as DEPTH OVER THE GROUND THE WRECKAGE COVERS rather than as the sum of the
  # lumps, because the lumps overlap by design and overlapping lumps do not stack their
  # heights. What the material comes to when it is spread over the footprint and its skirt
  # is the honest figure, and it is what a collapsed house actually looks like: about a
  # metre, mounded.
  test "the heaps are as deep as the material comes to over the ground they cover" do
    set = surface
    kept = material_volume * Game::Building::Rubble::BULK * Game::Building::Rubble::SHARE
    ground = pile_count(set) * Game::Building::Rubble::CELL**2

    assert_in_delta kept / ground, set.thickness, 0.02
  end

  # Wreckage covers the ground the building stood on. At 58% it read as scattered lumps on
  # a site rather than as the site being buried, which is the wrong picture: a house does
  # not fall down and leave most of its own floor showing.
  test "the wreckage covers the ground the house stood on" do
    set = surface
    side = Game::Building::Rubble::CELL * Game::Building::Rubble::SPREAD
    covered = Game::Building::Rubble.total_piles(set) * side * side

    assert_operator covered, :>, 12.0 * 15.0,
                    "the lumps do not between them cover the footprint even once"
  end

  # Enough shapes that a site does not read as one lump repeated. They cost a draw call
  # each, but the pools are shared by every building in the world, so this is the cost for
  # a city and not the cost per house.
  test "there are enough different lumps to go round" do
    assert_operator Game::Building::Rubble::SHAPES, :>=, 12
  end

  # The consequence that matters, and the reason this is derived rather than tuned: a
  # bigger building leaves a bigger mess, for ever, without anybody choosing a number.
  test "a taller house leaves deeper heaps on the same footprint" do
    one = surface(storeys: 1, eaves: 3.0, ridge: 5.0)
    three = surface

    assert_operator three.thickness, :>, one.thickness * 2,
                    "three storeys of material should not pile up like one"
  end

  # Cells are centred on their surface plane, which is right for a wall -- its thickness
  # straddles the line its origin describes -- and wrong for a heap on the ground, which
  # would be buried to its waist. Half of every heap was underground, and that is most of
  # why they read as paving slabs rather than as rubble.
  test "a heap sits on the ground rather than half in it" do
    set = surface

    assert_in_delta set.thickness / 2.0, set.origin.y, 0.001
  end

  # Wreckage piles up in the middle of what fell, so the heaps nearest the centre are the
  # ones that exist first -- a half-collapsed building leaves a mound where it stood rather
  # than a ring around its edge.
  #
  # The ORDER is shared with the client, not just the count. The server gates damage on the
  # revealed prefix, so a client revealing a different subset would show you heaps you
  # cannot clear and hide heaps it thinks are there.
  test "piles are ordered outward from the middle" do
    set = surface
    indices = Game::Building::Rubble.pile_indices(set)

    # Quantised, exactly as the ordering quantises. Cells mirrored across the grid are the
    # same distance out in every sense that matters, and comparing raw floats here would be
    # asserting a last-bit tie-break that the implementation deliberately does not have.
    radii = indices.map do |index|
      local = index - set.piece_offset
      (Game::Building::Rubble.radius(set, local / set.cols, local % set.cols) * 1_000_000).round
    end

    assert_equal radii.sort, radii, "the piles are not ordered by distance from the centre"
    assert_operator radii.first, :<, radii.last
  end

  # Ordering must be total and stable, or two processes could disagree about which heaps a
  # partial collapse left -- and disagree permanently, since collapsed_from never moves back.
  test "the order does not depend on how the piles were found" do
    assert_equal Game::Building::Rubble.pile_indices(surface),
                 Game::Building::Rubble.pile_indices(surface)
  end

  # A heap is drawn from what the building was made of, in proportion. The shares are
  # worked out here from the surfaces the generator built, and shipped, so a bungalow with
  # a flat concrete roof leaves different wreckage from a gabled brick house without
  # anybody choosing a number.
  test "the wreckage is what the house was made of, by share" do
    mix = surface.mix

    assert mix, "the rubble surface carries no mix"
    assert_in_delta 1.0, mix.sum(&:last), 1e-6
    names = mix.map(&:first)
    assert_equal names, names.uniq
    refute_includes names, :void, "a hole is not a material"
    refute_includes names, :rubble, "rubble is what the chunks sit in, not a chunk"
    assert_equal :brick, names.first, "a brick house should be mostly brick"
    assert_includes names, :timber
    assert_equal mix, mix.sort_by { |name, share| [ -share, name ] }, "shares are shipped largest first"
  end

  test "the mix ships with the surface and nothing else carries one" do
    set = Game::Building::Generator.call(recipe)
    rubble = set.surfaces.last
    wall = set.surfaces.first

    assert_equal rubble.mix.map { |name, share| [ name.to_s, share.round(4) ] }, rubble.to_spec[:mix]
    assert_nil wall.mix
    refute wall.to_spec.key?(:mix), "a wall has no business shipping a mix"
  end

  # A pile the size of the house that fell. The share of the house that stays as wreckage
  # is a feel number and will move, but the CONSEQUENCE is what this pins: a three-storey
  # house leaves wreckage that averages more than a metre over its footprint -- not a rug
  # -- and less than a storey, which would be a hill. How tall the pile stands is a picture
  # and not an obstacle: the truck's wheel rays pass through heaps and the blade breaks
  # whatever it meets, so this number is free to say what a fallen house looks like.
  test "a three-storey house leaves a pile, not a rug and not a hill" do
    assert_operator surface.thickness, :>, 1.0,
                    "#{surface.thickness.round(2)}m of wreckage is a rug under a twelve metre ridge"
    assert_operator surface.thickness, :<, recipe.storey_height,
                    "#{surface.thickness.round(2)}m of wreckage wall to wall is a hill"
  end
end
