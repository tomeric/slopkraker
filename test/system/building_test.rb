require "application_system_test_case"

# A building is 652 pieces expanded from 22 surfaces, and every one of them can be hit.
#
# Driven through the piece hooks rather than by aiming a car at a wall. Aiming and hoping
# is where most of this suite's flakiness comes from, and nothing worth asserting about a
# break needs a collision to have caused it.
class BuildingTest < ApplicationSystemTestCase
  setup do
    visit_world("targets")
    wait_for(message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
  end

  test "the house arrives with every one of its pieces" do
    assert_equal 652, telemetry["pieces"]
    assert_equal 1, telemetry["buildings"].length
    assert_equal "house", telemetry["buildings"].first["name"]
  end

  # Void cells -- the doorway, the clipped corners of the gables -- hold an index but are
  # never standing. 652 pieces, sixteen of them nothing at all.
  test "void cells hold an index but nothing else" do
    assert_equal 636, telemetry["piecesStanding"]
    assert_equal 0, telemetry["piecesBroken"]
  end

  test "the materials Ruby generated are the materials the browser built" do
    materials = page.evaluate_script(<<~JS)
      (() => {
        const seen = {}
        for (let i = 0; i < window.__arena.pieces; i += 1) {
          const piece = window.__arenaPieceState(i)
          seen[piece.material] = (seen[piece.material] || 0) + 1
        }
        return seen
      })()
    JS

    assert_equal({
      "timber" => 161, "brick" => 152, "roof_tile" => 100, "concrete" => 80,
      "steel" => 48, "plaster" => 48, "glass" => 47, "void" => 16
    }, materials)
  end

  test "breaking a piece takes it out of the world" do
    standing = telemetry["piecesStanding"]
    page.execute_script("window.__arenaBreak(0)")

    # The readout is assembled once a frame, so it lags the break by up to one.
    wait_for(message: "the piece count never dropped") { telemetry["piecesBroken"] == 1 }
    assert_equal standing - 1, telemetry["piecesStanding"]
    assert_not page.evaluate_script("window.__arenaPieceState(0).standing")
  end

  # The whole reason a break disables a collider rather than removing one: the server has
  # the last word on whether a break really happened, and putting a piece back has to be
  # possible without recreating anything.
  test "a broken piece can be put back" do
    page.execute_script("window.__arenaBreak(0)")
    wait_for(message: "the piece never broke") { telemetry["piecesBroken"] == 1 }

    page.execute_script("window.__arenaRestore(0)")

    wait_for(message: "the piece never came back") { telemetry["piecesBroken"] == 0 }
    assert page.evaluate_script("window.__arenaPieceState(0).standing")
  end

  test "a piece survives damage it can absorb and goes when it cannot" do
    before = page.evaluate_script("window.__arenaPieceState(0)")
    assert_operator before["maxHealth"], :>, 0

    page.execute_script("window.__arenaDamagePiece(0, #{before["maxHealth"] / 2})")
    assert page.evaluate_script("window.__arenaPieceState(0).standing"), "half its health should not finish it"

    page.execute_script("window.__arenaDamagePiece(0, #{before["maxHealth"]})")
    assert_not page.evaluate_script("window.__arenaPieceState(0).standing")
  end

  # The point of the material table: glass goes on contact and concrete does not.
  test "glass gives way long before concrete does" do
    healths = page.evaluate_script(<<~JS)
      (() => {
        const out = {}
        for (let i = 0; i < window.__arena.pieces; i += 1) {
          const piece = window.__arenaPieceState(i)
          if (!out[piece.material]) out[piece.material] = piece.maxHealth
        }
        return out
      })()
    JS

    assert_operator healths["glass"], :<, healths["brick"]
    assert_operator healths["brick"], :<, healths["concrete"]
    assert_operator healths["concrete"], :<, healths["steel"]
  end

  # One draw call per material rather than one per piece. 652 pieces rendering as seven
  # draws is the thing that makes a city conceivable at all.
  test "the house costs a draw call per material, not per piece" do
    assert_operator page.evaluate_script("window.__arenaDraws()"), :<, 40
  end

  private
    def telemetry
      page.evaluate_script("window.__arena")
    end
end
