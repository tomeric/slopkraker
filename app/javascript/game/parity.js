import { TurboBar } from "game/turbo_bar"
import { resolveDamage, explosionRadius, explosionForce } from "game/damage"
import { eachCell } from "game/world/surface"

// The ported pairs, reachable from a test. Every entry takes its inputs from the page so
// the Ruby side of parity_test.rb can hand both languages the same cases in one round
// trip and hold them to the same answers. Nothing here is used by the game.
export function installParityHooks({ spec, buildings, terrain }) {
  const materials = spec.materials

  window.__arenaParity = {
    // A script of ["draw", amount] and ["update", dt]; the level after each.
    turboBar(barSpec, ops) {
      const bar = new TurboBar(barSpec)
      return ops.map(([ op, value ]) => {
        if (op === "draw") bar.draw(value)
        else bar.update(value)
        return bar.level
      })
    },

    // Cases of { vehicle, part, material, kind, state, speed }; the damage for each.
    damage(rules, cases) {
      return cases.map(({ vehicle, part, material, kind, state, speed }) => resolveDamage({
        rules, speed, kind, state: state || {},
        part: part ? spec.vehicles[vehicle].parts.find((p) => p.name === part) : null,
        material: material ? materials[material] : null
      }))
    },

    explosion(explosionSpec, times, distances) {
      return {
        radius: times.map((t) => explosionRadius(explosionSpec, t)),
        force: distances.map((d) => explosionForce(explosionSpec, d))
      }
    },

    // Every cell of a building in index order, with its material.
    surface(buildingId) {
      const building = buildings.find(buildingId)
      const out = []
      for (const surface of building.spec.surfaces) {
        eachCell(surface, null, (index, material) => out.push([ index, material ]))
      }
      return out
    },

    terrain(points) {
      return points.map(([ x, z ]) => (terrain ? terrain.heightAt(x, z) : null))
    }
  }
}
