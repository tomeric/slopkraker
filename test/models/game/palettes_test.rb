require "test_helper"

class Game::PalettesTest < ActiveSupport::TestCase
  test "every palette names every role, as a colour" do
    Game::Palettes::TABLE.each do |name, palette|
      assert_equal Game::Palettes::ROLES.sort, palette.keys.sort, "#{name} is missing a role"
      palette.each_value { |colour| assert_match(/\A#[0-9a-f]{6}\z/i, colour, "#{name}") }
    end
  end

  # A material that names a role the palettes do not carry would be coloured by nothing.
  test "every role a material asks for is one every palette carries" do
    Game::Materials::TABLE.each_value do |material|
      next if material.role.nil?

      assert_includes Game::Palettes::ROLES, material.role, "#{material.name} asks for #{material.role}"
    end
  end

  test "the default palette exists and is what the hand-made worlds are drawn in" do
    assert Game::Palettes.key?(Game::Palettes::DEFAULT)
    assert_equal Game::Materials.fetch(:brick).colour, Game::Palettes.fetch(Game::Palettes::DEFAULT)[:brick],
                 "brown_brick is tuned to reproduce today's brick"
  end

  test "the table serialises with string keys and without leaking ruby objects" do
    round_tripped = JSON.parse(Game::Palettes.to_spec.to_json)

    assert_equal Game::Palettes.names.map(&:to_s).sort, round_tripped.keys.sort
    assert_equal Game::Palettes::ROLES.map(&:to_s).sort, round_tripped["red_brick"].keys.sort
  end
end
