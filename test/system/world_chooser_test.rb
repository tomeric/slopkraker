require "application_system_test_case"

# The front door. A bare visit names no world, so rather than guessing one it offers the
# choice -- and a link with a typo in it says so instead of quietly loading somewhere else.
class WorldChooserTest < ApplicationSystemTestCase
  test "visiting without a world offers the ones there are" do
    visit root_path

    assert_selector "h1", text: "Carnavalskraker"
    assert_selector ".world__name", text: "Flat"
    assert_selector ".world__name", text: "Targets"
    assert_no_selector "canvas.arena__canvas"
  end

  test "each world says what is in it" do
    visit root_path

    assert_selector ".world", text: "3 crates"
    assert_selector ".world", text: "pillar"
  end

  test "picking a world loads it with the vehicle chosen" do
    visit root_path
    # Which row matters now: every world offers each vehicle twice, once to continue and
    # once to start clean.
    within(".world", text: "Targets") { within(".world__row--continue") { click_link "Buggy" } }

    wait_for(message: "engine never booted") do
      page.evaluate_script("!!(window.__arena && window.__arena.ready)")
    end

    assert_equal "buggy", page.evaluate_script("window.__arena.vehicle")
    assert_equal 4, page.evaluate_script("window.__arena.bodies"), "should be in Targets"
  end

  # The failure this prevents: a typo'd slug quietly loading flat ground, so a test or a
  # player measures the wrong world and the mistake never surfaces.
  test "an unknown world says so rather than loading another one" do
    visit root_path(params: { world: "nope" })

    assert_selector ".chooser__note", text: "no world called"
    assert_no_selector "canvas.arena__canvas"
  end

  # The bug this exists to fix: every link used to go to the shared lobby, so a world you
  # had already flattened stayed flattened and there was no way from the front door to a
  # clean one.
  test "a new match starts from a world nobody has touched" do
    wreck_the_lobby

    visit root_path
    within(".world", text: "Targets") { within(".world__row--fresh") { click_link "Buggy" } }
    wait_for(message: "engine never booted") do
      page.evaluate_script("!!(window.__arena && window.__arena.ready)")
    end

    building = page.evaluate_script("window.__arenaBuildingIds()[0]")
    assert page.evaluate_script("window.__arenaPieceState(0, arguments[0]).standing", building),
           "a new match should hand you a house nobody has hit"
  end

  test "the new match link carries a name of its own" do
    visit root_path
    fresh = within(".world", text: "Targets") { find(".world__row--fresh a", text: "Buggy")[:href] }

    assert_match(/match=[a-z]+-[a-z]+-[0-9a-f]{4}/, fresh)
  end

  # Two worlds must not share one generated name. Match.start binds a key to the first
  # world it is used with and keeps it, so a shared name would send you somewhere else.
  # Within one world the two vehicles deliberately DO share a name -- it is one match you
  # are starting, and which car you take into it is a separate choice.
  test "each world offers its own new match" do
    visit root_path
    per_world = all(".world").map do |world|
      world.all(".world__row--fresh a").map { |link| link[:href][/match=([^&]+)/, 1] }
    end

    per_world.each { |names| assert_equal 1, names.uniq.length, "one world offered two names" }

    firsts = per_world.map(&:first)
    assert_equal firsts.uniq, firsts, "two worlds offered the same match name"
  end

  private
    def wreck_the_lobby
      world = World.find_by!(slug: "targets")
      match = Match.start(key: "lobby", world: world)
      house = world.world_objects.find_by!(kind: "building")
      Game::Damage::Registry.checkout(match) do |state|
        state.apply_batch([ [ house.id, 0, 5000.0, "impact" ] ])
      end
    end
end
