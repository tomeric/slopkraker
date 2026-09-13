import RAPIER from "@dimforge/rapier3d-compat"

// RAPIER.init() is NOT idempotent: each call re-decodes the inlined wasm and swaps the
// module-level exports, silently orphaning every handle from a previous world. Turbo
// navigations make a second call inevitable, so memoise the promise at module scope.
let booting = null

export function loadRapier() {
  booting ||= RAPIER.init().then(() => RAPIER)
  return booting
}
