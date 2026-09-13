require "test_helper"

class Game::MaterialsTest < ActiveSupport::TestCase
  test "every material is complete and finite" do
    Game::Materials::TABLE.each do |name, material|
      assert_equal name, material.name
      assert_operator material.health_per_m2, :>=, 0, "#{name} health"
      assert_operator material.density, :>=, 0, "#{name} density"
      assert_match(/\A#[0-9a-f]{6}\z/i, material.colour, "#{name} colour")

      Game::Material::KINDS.each do |kind|
        value = material.multiplier_for(kind)
        assert_kind_of Float, value, "#{name} #{kind}"
        assert value.finite?, "#{name} #{kind} must be finite"
        assert_operator value, :>, 0, "#{name} #{kind}"
      end
    end
  end

  test "the table serialises without leaking ruby objects" do
    round_tripped = JSON.parse(Game::Materials.to_spec.to_json)

    assert_equal Game::Materials.names.map(&:to_s).sort, round_tripped.keys.sort
    assert_equal 1.0, round_tripped.dig("brick", "multipliers", "impact")
  end

  # Void is a doorway or the clipped corner of a gable: a real piece index with nothing in
  # it. Every cull would otherwise have to happen identically in Ruby and in JavaScript.
  test "void is inert" do
    void = Game::Materials.fetch(:void)

    assert_equal 0.0, void.health_for(4.0, 0.3)
    assert_equal 0.0, void.mass_for(4.0, 0.3)
    assert_not_predicate void, :structural?
  end

  test "glass holds nothing up" do
    assert_not_predicate Game::Materials.fetch(:glass), :structural?
    assert_predicate Game::Materials.fetch(:brick), :structural?
  end

  # The ordering that makes the world read correctly: a pane goes on contact, a plaster
  # partition is barely there, brick takes a solid hit, concrete wants a rocket.
  test "materials are ordered from glass to steel" do
    order = %i[glass plaster roof_tile timber brick concrete steel]
    healths = order.map { |name| Game::Materials.fetch(name).health_per_m2 }

    assert_equal healths.sort, healths, "expected #{order.inspect} to be increasing"
  end

  test "a cell's health and mass follow its area and thickness" do
    brick = Game::Materials.fetch(:brick)

    assert_operator brick.health_for(4.0, 0.25), :>, brick.health_for(2.0, 0.25)
    assert_operator brick.health_for(2.0, 0.5), :>, brick.health_for(2.0, 0.25)
    assert_in_delta 1800.0 * 2.25 * 0.25, brick.mass_for(2.25, 0.25), 1e-6
  end

  # Twice as thick should not be twice as hard to breach; what fails is the face being
  # punched through, not the whole volume at once.
  test "thickness helps less than in proportion" do
    brick = Game::Materials.fetch(:brick)
    doubled = brick.health_for(1.0, 0.5) / brick.health_for(1.0, 0.25)

    assert_operator doubled, :>, 1.0
    assert_operator doubled, :<, 2.0
  end

  # --- nothing is invincible ------------------------------------------------------
  #
  # The property that matters more than any individual number: hardness decides how LONG
  # something takes to break, never WHETHER it breaks. A wall a car can never damage is
  # indistinguishable, from the driver's seat, from a wall that is broken.

  def resolver
    @resolver ||= Game::DamageResolver.new(**Game::Spec.default_rules[:damage])
  end

  test "every material gives way to repeated hits, even a slow one" do
    # A 1.5m cell at 12 m/s: a shunt, not a run-up.
    area = 2.4
    thickness = 0.3

    Game::Materials::TABLE.each do |name, material|
      next if name == :void

      landed = resolver.resolve(part: nil, speed: 12.0, material: material, kind: :impact)
      assert_operator landed, :>, 0, "#{name} shrugs off a 12m/s hit entirely"

      hits = (material.health_for(area, thickness) / landed).ceil
      assert_operator hits, :<, 500, "#{name} needs #{hits} hits, which is not a wall but a bug"
    end
  end

  # Measured at a shunt, not at speed. Everything gives way to a good hit now -- that is
  # the whole point of the tuning -- so the ordering is only visible where a car is going
  # slowly enough for toughness to still be deciding anything.
  test "hardness decides how long, not whether" do
    area = 2.4
    hits = ->(name) {
      material = Game::Materials.fetch(name)
      (material.health_for(area, 0.3) /
        resolver.resolve(part: nil, speed: 8.0, material: material, kind: :impact)).ceil
    }

    assert_equal 1, hits.call(:glass)
    assert_operator hits.call(:brick), :<, hits.call(:concrete)
    assert_operator hits.call(:concrete), :<, hits.call(:steel)
  end

  # And at driving speed the ordering stops mattering, which is the intended feel.
  test "a good hit gets through anything but concrete and steel" do
    area = 2.4
    %i[glass plaster roof_tile timber brick].each do |name|
      material = Game::Materials.fetch(name)
      landed = resolver.resolve(part: nil, speed: 18.0, material: material, kind: :impact)

      assert_operator landed, :>=, material.health_for(area, 0.3),
        "#{name} should give way to one solid hit"
    end
  end

  test "a rocket gets through what a car cannot" do
    steel = Game::Materials.fetch(:steel)
    floor = Game::Spec.default_rules[:damage][:minimum_fraction]

    shunt = resolver.resolve(part: nil, speed: 12.0, material: steel, kind: :impact)
    blast = steel.absorb(190.0 * steel.multiplier_for(:blast), floor)

    assert_operator blast, :>, shunt * 20, "explosives should be the answer to steel"
  end
end
