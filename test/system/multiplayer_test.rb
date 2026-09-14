require "application_system_test_case"

# Two players in one match, each in their own browser session. The only test in the suite
# that runs two engines at once, and the only way to prove remote cars without faking the
# thing being proved -- a synthetic snapshot would exercise the interpolator and tell us
# nothing about whether a real client ever sends one.
class MultiplayerTest < ApplicationSystemTestCase
  MATCH = "two-up".freeze

  def boot(vehicle)
    visit_world("targets", vehicle: vehicle, match: MATCH)
    wait_for(message: "engine never booted") do
      page.evaluate_script("!!(window.__arena && window.__arena.ready)")
    end
  end

  def remotes
    page.evaluate_script("window.__arenaRemotes()")
  end

  test "each player sees the other's car" do
    boot("monster_truck")

    Capybara.using_session(:second) do
      boot("buggy")

      wait_for(timeout: 20, message: "the second player never saw the first") { remotes.positive? }
      assert_equal 1, remotes, "should see exactly one other car"
    end

    wait_for(timeout: 20, message: "the first player never saw the second") { remotes.positive? }
    assert_equal 1, remotes
  end

  # Nobody is their own opponent. The server stamps player_id and NetConnection drops our
  # own echo, so a car that appeared here would be this client watching itself.
  test "a player alone in a match sees nobody" do
    boot("buggy")
    sleep 1.5

    assert_equal 0, remotes
  end

  test "a car goes when its driver does" do
    boot("monster_truck")

    Capybara.using_session(:second) do
      boot("buggy")
      wait_for(timeout: 20, message: "never saw the first player") { remotes.positive? }
    end

    wait_for(timeout: 20, message: "never saw the second player") { remotes.positive? }

    Capybara.using_session(:second) { visit root_path }

    wait_for(timeout: 20, message: "the car stayed after its driver left") { remotes.zero? }

    assert_equal 0, remotes
  end
end
