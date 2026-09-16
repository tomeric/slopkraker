require "application_system_test_case"

# A building is 1553 pieces expanded from 23 surfaces, and every one of them can be hit.
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
    assert_equal 1553, telemetry["pieces"]
    assert_equal 1, telemetry["buildings"].length
    assert_equal "house", telemetry["buildings"].first["name"]
  end

  # Void cells -- the doorway, the clipped corners of the gables, and the squares of the
  # rubble grid that fall outside the footprint -- hold an index but are never standing. So
  # do the heaps themselves until the house falls on them: 1553 indices, of which 1398 are
  # the building, 75 are dormant wreckage and 80 are nothing at all. Every square of ground
  # the house actually stood on holds debris, which is what stops the mound having holes;
  # the void is the doorway, the gables' clipped corners, and the thinned-out edge of the
  # rubble grid's ragged skirt.
  test "void cells hold an index but nothing else" do
    assert_equal 1398, telemetry["piecesStanding"]
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
      "brick" => 445, "timber" => 366, "roof_tile" => 224, "concrete" => 180,
      "plaster" => 108, "glass" => 72, "void" => 80, "steel" => 3, "rubble" => 75
    }, materials)
  end

  # A hit takes the whole block, not the cell it landed on -- which is what makes a hole
  # follow a shape rather than a square.
  test "breaking a piece takes its whole block out of the world" do
    standing = telemetry["piecesStanding"]
    block = page.evaluate_script("window.__arenaPieceBlock(0)")
    assert_operator block.length, :>, 1, "piece 0 should belong to a real block"

    page.execute_script("window.__arenaBreak(0)")

    # The readout is assembled once a frame, so it lags the break by up to one.
    wait_for(message: "the block never went") { telemetry["piecesBroken"] == block.length }
    assert_equal standing - block.length, telemetry["piecesStanding"]
    block.each do |cell|
      assert_not page.evaluate_script("window.__arenaPieceState(#{cell}).standing")
    end
  end

  # The whole reason a break disables a collider rather than removing one: the server has
  # the last word on whether a break really happened, and putting a piece back has to be
  # possible without recreating anything.
  test "a broken block can be put back" do
    page.execute_script("window.__arenaBreak(0)")
    wait_for(message: "the block never broke") { telemetry["piecesBroken"].positive? }

    page.execute_script("window.__arenaRestore(0)")

    wait_for(message: "the block never came back") { telemetry["piecesBroken"].zero? }
    assert page.evaluate_script("window.__arenaPieceState(0).standing")
  end

  # Glass is deliberately left out of the tiling: a pane grouped with the brick around it
  # would take half a wall with it when it broke.
  test "a pane is its own block" do
    pane = page.evaluate_script(<<~JS)
      (() => {
        for (let i = 0; i < window.__arena.pieces; i += 1) {
          if (window.__arenaPieceState(i).material === "glass") return i
        }
        return -1
      })()
    JS

    assert_equal [ pane ], page.evaluate_script("window.__arenaPieceBlock(#{pane})")
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

  # One draw call per material rather than one per piece. 1502 pieces rendering as eight
  # draws is the thing that makes a city conceivable at all.
  #
  # The number is a ceiling with room in it rather than a budget: what this catches is the
  # render plan regressing to per-piece, which at fifteen hundred pieces would be hundreds
  # of draws and nowhere near this. It was 40 while the house was made of seven materials
  # and rubble made it eight, which left it sitting exactly on the limit.
  test "the house costs a draw call per material, not per piece" do
    assert_operator page.evaluate_script("window.__arenaDraws()"), :<, 45
  end

  private
    def telemetry
      page.evaluate_script("window.__arena")
    end
end
