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
end
