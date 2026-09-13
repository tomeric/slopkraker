import { AudioEngine } from "game/audio/audio_engine"
import { EngineSound } from "game/audio/engine_sound"
import { NoiseLoop, TurboWhoosh, OneShots } from "game/audio/effects"

// Assembles the voices a given vehicle needs from its Ruby audio spec. A vehicle without
// jets simply has no jets block, so no jet voice is built.
export class VehicleAudio {
  constructor(element, vehicleSpec) {
    const audio = vehicleSpec.audio
    this.engine = new AudioEngine(element)

    this.engineSound = this.engine.add(new EngineSound(audio.engine, vehicleSpec))

    if (audio.turbo) {
      this.engine.add(new TurboWhoosh(audio.turbo))
    }
    if (audio.jets) {
      this.engine.add(new NoiseLoop(audio.jets, { amountFor: (t) => t.jets }))
    }
    if (audio.skid) {
      // Tyre squeal tracks how fast rubber is being dragged sideways, not slip angle.
      this.engine.add(new NoiseLoop(audio.skid, {
        amountFor: (t) => (t.grounded > 0 ? Math.min(Math.abs(t.slip) / 9, 1) : 0)
      }))
    }

    this.oneShots = this.engine.add(new OneShots(this.engine))
    this.spec = audio
    this.wasAirborne = false
  }

  update(dt, telemetry) {
    this.engine.update(dt, telemetry)

    // Landing thump, on the transition back to the ground.
    const airborne = telemetry.grounded === 0
    if (this.wasAirborne && !airborne && this.spec.landing) {
      this.oneShots.knock(this.spec.landing, Math.min(Math.abs(telemetry.fallSpeed || 0) / 14, 1))
    }
    this.wasAirborne = airborne
  }

  get muted() {
    return this.engine.muted
  }

  toggleMute() {
    return this.engine.toggleMute()
  }

  rocketFired() {
    if (this.spec.rocket) this.oneShots.fire(this.spec.rocket)
  }

  impact(intensity) {
    if (this.spec.impact) this.oneShots.knock(this.spec.impact, intensity)
  }

  dispose() {
    this.engine.dispose()
  }
}
