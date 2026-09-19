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
  #
  # The claim is about the SIZE of the space, so that is what is asserted. Demanding 500
  # draws come out all distinct tests the random number generator instead, and it FAILS BY
  # DESIGN: 500 draws from 26.2 million names expect 0.0048 collisions by the birthday
  # bound, so about one run in two hundred goes red for no reason at all. It did, during a
  # review on 2026-09-19 -- 499 unique out of 500 -- and a suite that cries wolf once a
  # fortnight is worse than one that does not check this at all.
  test "there are enough names that a collision is an accident rather than a matter of time" do
    space = Game::MatchName::ADJECTIVES.length * Game::MatchName::NOUNS.length * 16**4

    assert_operator space, :>, 20_000_000, "the tag is what keeps two words apart"
  end

  # And the generator really does reach across that space rather than favouring a corner
  # of it. One collision is luck; a handful means the draw is not what the arithmetic above
  # assumes, which is the failure actually worth catching.
  test "it does not repeat itself" do
    names = 500.times.map { Game::MatchName.generate }

    assert_operator names.uniq.length, :>=, names.length - 1
  end
end
