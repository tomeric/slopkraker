import * as THREE from "three"

// The jump jets, made visible. Physics applies one impulse at the centre of mass and one
// torque impulse for attitude (vehicles/vehicle.js) -- these nozzles carry no forces at
// all. What they do is answer the question the driver otherwise cannot see: which way is
// this burn pointing?
//
// A nozzle underneath pushes its own corner UP, so the corners that burn are the ones
// lifting the side that has to rise. Ruby encodes that in roll_bias/pitch_bias per nozzle
// (parts/jump_jets.rb) precisely so the sign convention lives in one testable place; this
// file only mixes what it is handed.
//
// Built like RocketPlume: plain primitives, additive blending, no textures. Shorter than
// a rocket's though -- Ruby sets flame_length at a few times the nozzle radius against the
// rocket's eleven, because this is a thruster, not a launch vehicle.
export class Boosters {
  constructor(group, jets) {
    this.flame = jets.flame || {}
    // Unit primitives scaled per nozzle: the standing pattern here, and it keeps five
    // boosters down to two geometries.
    this.coneGeometry = new THREE.ConeGeometry(1, 1, 12)
    this.glowGeometry = new THREE.SphereGeometry(1, 10, 8)
    this.housingGeometry = new THREE.CylinderGeometry(1, 1, 1, 12)
    this.housingMaterial = new THREE.MeshStandardMaterial({
      color: "#2b333f", roughness: 0.4, metalness: 0.7
    })

    this.nozzles = (jets.nozzles || []).map((nozzle) => this.build(group, nozzle))
  }

  build(group, nozzle) {
    const dir = new THREE.Vector3(...nozzle.direction)
    const [x, y, z] = nozzle.offset
    // ConeGeometry's apex is at +Y, so aiming +Y down the exhaust makes the flame taper
    // AWAY from the mouth. The underside/roof split then falls out of the data rather
    // than out of a branch in here.
    const aim = new THREE.Quaternion().setFromUnitVectors(new THREE.Vector3(0, 1, 0), dir)

    const housing = new THREE.Mesh(this.housingGeometry, this.housingMaterial)
    housing.scale.set(nozzle.radius * 1.35, nozzle.radius * 1.2, nozzle.radius * 1.35)
    housing.position.set(x, y, z)
    housing.quaternion.copy(aim)
    housing.castShadow = true
    group.add(housing)

    const flame = new THREE.Mesh(this.coneGeometry, new THREE.MeshBasicMaterial({
      color: this.flame.core_colour, transparent: true, opacity: 1,
      depthWrite: false, blending: THREE.AdditiveBlending
    }))
    flame.quaternion.copy(aim)
    flame.visible = false
    group.add(flame)

    const glow = new THREE.Mesh(this.glowGeometry, new THREE.MeshBasicMaterial({
      color: this.flame.glow_colour, transparent: true, opacity: 1,
      depthWrite: false, blending: THREE.AdditiveBlending
    }))
    glow.position.set(x, y, z)
    glow.visible = false
    group.add(glow)

    return {
      spec: nozzle,
      flame,
      glow,
      dir,
      // The mouth the flame grows out of, so the cone can be pushed along `dir` by half
      // its own (scaled) length every frame without re-deriving this.
      mouth: new THREE.Vector3(x, y, z),
      intensity: 0
    }
  }

  // `state` is MonsterTruck#boosterState(). Absent for any vehicle without jets.
  update(dt, state) {
    if (!this.nozzles.length) return

    const { tilt_authority: authority = 1, response = 16, flicker, opacity, glow_scale: glowScale = 1.6 } = this.flame
    // A render-rate lerp: 1 - e^(-k dt) rather than k*dt, so the easing does not change
    // with frame rate.
    const ease = 1 - Math.exp(-response * (dt || 0))

    for (const nozzle of this.nozzles) {
      const target = this.targetFor(nozzle.spec, state, authority)
      nozzle.intensity += (target - nozzle.intensity) * ease
      this.draw(nozzle, flicker, opacity, glowScale)
    }
  }

  targetFor(spec, state, authority) {
    if (!state) return 0
    if (spec.group === "slam") return clamp01(state.slam)

    // Gated on the jets themselves: with nothing burning, a held stick must not light a
    // corner. The bias terms trim that base, they do not create it.
    const base = state.lift || 0
    if (base <= 0) return 0

    const bias = (state.roll || 0) * spec.roll_bias + (state.pitch || 0) * spec.pitch_bias
    return clamp01(base + authority * bias)
  }

  draw(nozzle, flicker = [ 0.8, 1.2 ], opacity = [ 0.7, 1 ], glowScale) {
    const lit = nozzle.intensity > 0.02
    nozzle.flame.visible = lit
    nozzle.glow.visible = lit
    if (!lit) return

    const { radius, flame_length: length } = nozzle.spec
    const jitter = flicker[0] + Math.random() * (flicker[1] - flicker[0])
    const reach = length * nozzle.intensity * jitter

    nozzle.flame.scale.set(radius, reach, radius)
    // Base at the mouth, apex out along the exhaust.
    nozzle.flame.position.copy(nozzle.dir).multiplyScalar(reach / 2).add(nozzle.mouth)
    nozzle.flame.material.opacity = opacity[0] + Math.random() * (opacity[1] - opacity[0])

    nozzle.glow.scale.setScalar(radius * glowScale * nozzle.intensity)
    nozzle.glow.material.opacity = 0.55 * nozzle.intensity
  }

  // Intensity per nozzle, for telemetry and the browser tests.
  get readout() {
    return this.nozzles.map(({ spec, intensity }) => ({ name: spec.name, intensity }))
  }

  // VehicleView#dispose only detaches its group, and disposeScene only reaches what is
  // still in the scene -- so anything built here has to be freed here, or every V press
  // leaks another five nozzles' worth.
  dispose() {
    for (const { flame, glow } of this.nozzles) {
      flame.material.dispose()
      glow.material.dispose()
    }
    this.coneGeometry.dispose()
    this.glowGeometry.dispose()
    this.housingGeometry.dispose()
    this.housingMaterial.dispose()
    this.nozzles = []
  }
}

function clamp01(value) {
  return Math.min(Math.max(value || 0, 0), 1)
}
