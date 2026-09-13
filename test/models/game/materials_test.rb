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

  # The ordering that makes the world read correctly: a pane goes on contact, brick takes
  # a few hits, concrete wants a rocket.
  test "materials are ordered from glass to concrete" do
    order = %i[glass roof_tile plaster timber brick concrete steel]
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
end
