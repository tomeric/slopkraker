require "test_helper"

class Game::MatchNameTest < ActiveSupport::TestCase
  test "it reads as two words and a tag" do
    assert_match(/\A[a-z]+-[a-z]+-[0-9a-f]{4}\z/, Game::MatchName.generate)
  end

  # The channel and the model both sanitise against this, and a generated name that failed
  # it would send every new match quietly back to the lobby -- which is the exact bug this
  # whole feature exists to fix.
  test "it is a name a match will accept" do
    200.times do
      name = Game::MatchName.generate

      assert_match Match::KEY_FORMAT, name
      assert_operator name.length, :<=, 32
    end
  end

  # A collision drops two strangers into each other's world. With the tag there are enough
  # names that it does not happen by accident.
  test "it does not repeat itself" do
    names = 500.times.map { Game::MatchName.generate }

    assert_equal names.length, names.uniq.length
  end
end
