require "application_system_test_case"

# How the world is DRAWN, asserted without reading pixels. The textures are painted at boot
# from the numbers in the spec, the texture coordinates run in metres along a surface, and
# the colours are a palette applied per instance -- each of which has a readout.
class LooksTest < ApplicationSystemTestCase
  def boot(world, quality:, match:, spawn: nil)
    visit_world(world, quality: quality, match: match, spawn: spawn)
    wait_for(timeout: 90, message: "#{world} never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
  end

  def looks = page.evaluate_script("window.__arenaLooks()")

  # `high` is where the detail lives: a texture per patterned material, none for steel.
  test "at high quality every patterned material is painted and steel is not" do
    boot("targets", quality: "high", match: "looks-high")
    readout = looks

    assert readout["enabled"]
    assert_equal 2, readout["tile"], "one texture covers two metres of surface"
    %w[brick roof_tile timber glass plaster concrete].each { |name| assert_includes readout["textured"], name }
    refute_includes readout["textured"], "steel", "steel is flat and reflective"
    refute_includes readout["textured"], "rubble"
    assert_empty severe_console_errors
  end

  # `low` is what the suite is calibrated on and must keep today's flat materials.
  test "at low quality nothing is painted" do
    boot("targets", quality: "low", match: "looks-low")
    readout = looks

    refute readout["enabled"]
    assert_empty readout["textured"]
  end

  # The front wall of the targets house: surface 0, twelve one-metre columns, three rows.
  # cellUV is the cell's offset along its surface in metres, so the bond runs on across it.
  test "texture coordinates run in metres along a wall" do
    boot("targets", quality: "low", match: "looks-uv")
    building = page.evaluate_script("window.__arenaBuildingIds()[0]")
    uv = ->(piece) { page.evaluate_script("window.__arenaCellUV(arguments[0], arguments[1])", piece, building) }

    assert_in_delta 0.0, uv.call(0)[0], 1e-6
    assert_in_delta 0.0, uv.call(0)[1], 1e-6
    assert_in_delta 1.0, uv.call(1)[0], 1e-6, "one cell along is one metre along"
    assert_in_delta 0.0, uv.call(1)[1], 1e-6
    assert_in_delta 0.0, uv.call(12)[0], 1e-6, "the next row starts again"
    assert_in_delta 1.0, uv.call(12)[1], 1e-6, "one row up is one metre up"
  end

  # Two rows in two palettes: the same material comes out a different colour, and the
  # church is drawn in the church's.
  test "buildings are coloured by their palette" do
    boot("geleen", quality: "low", match: "looks-palette")
    wait_for(timeout: 60, message: "the world never stepped") { page.evaluate_script("window.__arena.steps").positive? }
    pair = page.evaluate_script(<<~JS)
      (() => {
        const ids = window.__arenaBuildingIds()
        const byPalette = new Map()
        for (const id of ids) {
          const spec = window.__arenaBuildingSpec(id)
          if (spec.category !== "house") continue
          const wall = spec.surfaces.find(s => s.kind === "wall" && s.mat === "brick")
          if (!wall) continue
          // The first plain-brick cell of the wall: not a patch.
          let piece = null
          for (let i = wall.off; i < wall.off + wall.cols * wall.rows; i++) {
            if (window.__arenaPieceState(i, id).material === "brick") { piece = i; break }
          }
          if (piece === null || byPalette.has(spec.palette)) continue
          byPalette.set(spec.palette, { id, piece, palette: spec.palette, tint: window.__arenaTint(piece, id) })
          if (byPalette.size === 2) break
        }
        return [ ...byPalette.values() ]
      })()
    JS

    assert_equal 2, pair.length, "the estate is drawn in one palette"
    refute_equal pair[0]["tint"], pair[1]["tint"], "#{pair[0]['palette']} and #{pair[1]['palette']} colour brick the same"
    pair.each { |p| assert_match(/\A#[0-9a-f]{6}\z/, p["tint"]) }
    church = page.evaluate_script("window.__arenaBuildingIds().map(i => window.__arenaBuildingSpec(i)).find(s => s.category === 'church').palette")
    assert_equal "church", church
  end
end
