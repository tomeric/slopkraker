require "test_helper"

class Game::Building::SurfaceTest < ActiveSupport::TestCase
  def wall(**overrides)
    Game::Building::Surface.new(**{
      kind: :wall, storey: 0, material: Game::Materials.fetch(:brick),
      origin: Game::Vector3.new(0.1234567, 0, 0.7654321),
      u: Game::Vector3.new(0.7219454902358199, 0, -0.6919499325299205), v: Game::Vector3.new(0, 1, 0),
      width: 5.5700001, height: 2.8650001, cols: 6, rows: 3, thickness: 0.3, seed: 3
    }.merge(overrides))
  end

  test "the spec carries geometry rounded to what a metre needs" do
    spec = wall.to_spec

    assert_equal [ 0.12346, 0.0, 0.76543 ], spec[:o]
    assert_equal [ 0.72195, 0.0, -0.69195 ], spec[:u]
    assert_equal 5.57, spec[:w]
    assert_equal 2.865, spec[:h]
  end

  test "the health in the spec is exactly what the server will compute" do
    surface = wall
    brick = Game::Materials.fetch(:brick)

    assert_equal brick.health_for(surface.cell_area, surface.thickness), surface.to_spec[:hp]["brick"]
  end

  test "a surface belongs to bay 0 unless told otherwise, and says nothing about it" do
    assert_equal 0, wall.bay
    assert_nil wall.between
    assert_not wall.to_spec.key?(:bay)
    assert_not wall.to_spec.key?(:between)
  end

  test "a bay and a shared wall ride into the spec" do
    assert_equal 2, wall(bay: 2).to_spec[:bay]
    party = wall(between: [ 1, 2 ])
    assert party.shared?
    assert_equal [ 1, 2 ], party.to_spec[:between]
  end

  test "per-cell bays ride into the spec and survive an offset" do
    surface = wall(bays: [ 0 ] * 9 + [ 1 ] * 9).with_offset(40)

    assert_equal [ 0 ] * 9 + [ 1 ] * 9, surface.to_spec[:bays]
    assert_equal 40, surface.piece_offset
  end

  # The whole of what rotation is allowed to touch: origin, u, v, and therefore n. Every
  # index, every cell's material and every count is exactly as it was.
  test "rotating a surface turns its frame and nothing else" do
    surface = wall(origin: Game::Vector3.new(2, 0, 0), u: Game::Vector3.new(1, 0, 0), bay: 1).with_offset(7)
    turned = surface.rotated(Math::PI / 2)

    assert_in_delta 0.0, turned.origin.x, 1e-9
    assert_in_delta 2.0, turned.origin.z, 1e-9
    assert_in_delta 0.0, turned.u.x, 1e-9
    assert_in_delta 1.0, turned.u.z, 1e-9
    assert_equal surface.v, turned.v
    assert_equal [ surface.cols, surface.rows, surface.piece_offset, surface.bay ], [ turned.cols, turned.rows, turned.piece_offset, turned.bay ]
    assert_equal surface.patches, turned.patches
    assert_same surface, surface.rotated(0.0)
  end
end
