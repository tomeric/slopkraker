require "test_helper"

# The booster nozzles are the visible half of the truck's airborne attitude control, and
# every assertion about their placement here is really an assertion about the chassis axis
# convention in app/javascript/game/vehicles/vehicle.js:
#
#   forward = +Z, up = +Y, therefore right = forward x up = -X
#
# so the driver's LEFT is +X. Get that backwards and the whole effect mirrors: the truck
# banks one way while the boosters say the other. That is exactly the failure the comment
# at vehicle.js:142 warns about, and it is silent -- nothing crashes, it just lies.
class Game::Vehicles::MonsterTruckTest < ActiveSupport::TestCase
  def spec
    @spec ||= Game::Vehicles::MonsterTruck.build.to_spec
  end

  def jets
    spec[:parts].find { _1[:kind] == "jump_jets" }
  end

  def nozzles
    jets[:nozzles]
  end

  def lift
    nozzles.select { _1[:group] == "lift" }
  end

  def named(name)
    nozzles.find { _1[:name] == name } or raise "no nozzle named #{name}"
  end

  # The inboard face of a front wheel: anything wider than this is inside the tyre.
  def wheel_inner_edge
    wheel = spec[:wheels].find { _1[:name] == "front_left" }
    wheel[:position][0].abs - wheel[:width] / 2
  end

  test "the truck carries four lift nozzles and one slam nozzle" do
    assert_equal 4, lift.size
    assert_equal 1, nozzles.count { _1[:group] == "slam" }
    assert_equal 5, nozzles.size
  end

  test "lift nozzles sit at the four corners of the underside" do
    assert_equal [ "front_left", "front_right", "rear_left", "rear_right" ], lift.map { _1[:name] }.sort

    lift.each do |nozzle|
      x, y, z = nozzle[:offset]
      assert_operator y, :<, 0, "#{nozzle[:name]} is not underneath the truck"
      refute_equal 0, x, "#{nozzle[:name]} has no side"
      refute_equal 0, z, "#{nozzle[:name]} has no end"
    end
  end

  # +X is the driver's LEFT. A nozzle underneath pushes its corner UP, so the boosters
  # that fire are the ones lifting the side that has to rise.
  test "steering right lifts the left side, so the left nozzles carry positive roll bias" do
    assert_operator named("front_left")[:offset][0], :>, 0, "front_left is not on the +X side"
    assert_operator named("rear_left")[:offset][0], :>, 0, "rear_left is not on the +X side"

    assert_equal 1.0, named("front_left")[:roll_bias]
    assert_equal 1.0, named("rear_left")[:roll_bias]
  end

  test "the right nozzles carry the opposite roll bias" do
    assert_operator named("front_right")[:offset][0], :<, 0, "front_right is not on the -X side"
    assert_operator named("rear_right")[:offset][0], :<, 0, "rear_right is not on the -X side"

    assert_equal(-1.0, named("front_right")[:roll_bias])
    assert_equal(-1.0, named("rear_right")[:roll_bias])
  end

  # input.pitch is +1 nose-down. Dropping the nose means the REAR rises.
  test "nosing down lifts the rear, so the rear nozzles carry positive pitch bias" do
    assert_operator named("rear_left")[:offset][2], :<, 0, "rear_left is not behind the centre"
    assert_operator named("rear_right")[:offset][2], :<, 0, "rear_right is not behind the centre"

    assert_equal 1.0, named("rear_left")[:pitch_bias]
    assert_equal 1.0, named("rear_right")[:pitch_bias]
  end

  test "the front nozzles carry the opposite pitch bias" do
    assert_operator named("front_left")[:offset][2], :>, 0, "front_left is not ahead of the centre"
    assert_operator named("front_right")[:offset][2], :>, 0, "front_right is not ahead of the centre"

    assert_equal(-1.0, named("front_left")[:pitch_bias])
    assert_equal(-1.0, named("front_right")[:pitch_bias])
  end

  test "every lift nozzle has a mirror twin, so a centred stick burns symmetrically" do
    by_corner = lift.to_h { [ _1[:name], _1[:offset] ] }

    assert_equal by_corner["front_left"][0], -by_corner["front_right"][0]
    assert_equal by_corner["rear_left"][0], -by_corner["rear_right"][0]
    assert_equal by_corner["front_left"][2], -by_corner["rear_left"][2]
  end

  test "lift nozzles exhaust downwards and the slam nozzle exhausts upwards" do
    lift.each { assert_equal [ 0.0, -1.0, 0.0 ], _1[:direction], "#{_1[:name]} points the wrong way" }

    assert_equal [ 0.0, 1.0, 0.0 ], named("slam")[:direction]
    assert_operator named("slam")[:offset][1], :>, 0, "the slam nozzle is not on the roof"
  end

  # Air control is disabled while slamming -- vehicle.js bails on input.slide, which the
  # slam requires -- so there is no attitude for the roof nozzle to report.
  test "the slam nozzle does not answer the stick" do
    assert_equal 0.0, named("slam")[:roll_bias]
    assert_equal 0.0, named("slam")[:pitch_bias]
  end

  test "lift nozzles clear the tyres" do
    lift.each do |nozzle|
      reach = nozzle[:offset][0].abs + nozzle[:radius]
      assert_operator reach, :<, wheel_inner_edge, "#{nozzle[:name]} is inside the wheel"
    end
  end

  # Rocket-like, but a thruster rather than a launch vehicle: the rocket's own plume runs
  # eleven times its radius (render/rocket_plume.js).
  test "booster flames are stubbier than a rocket plume" do
    nozzles.each do |nozzle|
      ratio = nozzle[:flame_length] / nozzle[:radius]
      assert_operator ratio, :>, 2.0, "#{nozzle[:name]} is barely a flame"
      assert_operator ratio, :<, 5.0, "#{nozzle[:name]} is a rocket, not a booster"
    end
  end

  test "the flame carries the tuning the view needs" do
    flame = jets[:flame]

    assert_operator flame[:response], :>, 0, "flames would never reach their target"
    assert_operator flame[:tilt_authority], :>, 0, "the stick would not bias anything"
    assert flame[:core_colour].present?
    assert flame[:glow_colour].present?
  end
end
