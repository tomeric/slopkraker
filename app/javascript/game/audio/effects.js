import { noiseSource } from "game/audio/audio_engine"

// Continuous voice: bandpassed noise whose gain tracks a 0..1 amount. Used for the jets
// and for tyre skid, which differ only in tuning.
export class NoiseLoop {
  constructor(spec, { amountFor }) {
    this.spec = spec
    this.amountFor = amountFor
    this.nodes = null
  }

  attach(ctx, destination) {
    const spec = this.spec
    const output = ctx.createGain()
    output.gain.value = 0
    output.connect(destination)

    const filter = ctx.createBiquadFilter()
    filter.type = "bandpass"
    filter.frequency.value = spec.band_hz
    filter.Q.value = spec.q ?? 1.1
    filter.connect(output)

    const source = noiseSource(ctx)
    source.connect(filter)
    source.start()

    this.ctx = ctx
    this.nodes = { output, filter, source }
  }

  update(dt, telemetry) {
    if (!this.nodes) return
    const amount = Math.min(Math.max(this.amountFor(telemetry), 0), 1)
    const now = this.ctx.currentTime
    this.nodes.output.gain.setTargetAtTime(this.spec.gain * amount, now, 0.04)
    this.nodes.filter.frequency.setTargetAtTime(this.spec.band_hz * (0.8 + 0.5 * amount), now, 0.06)
  }

  dispose() {
    if (!this.nodes) return
    try { this.nodes.source.stop() } catch {}
    this.nodes.output.disconnect()
    this.nodes = null
  }
}

// Rising filtered-noise whoosh while the turbo is lit.
export class TurboWhoosh {
  constructor(spec) {
    this.spec = spec
    this.amount = 0
    this.nodes = null
  }

  attach(ctx, destination) {
    const output = ctx.createGain()
    output.gain.value = 0
    output.connect(destination)

    const filter = ctx.createBiquadFilter()
    filter.type = "bandpass"
    filter.frequency.value = this.spec.sweep_hz[0]
    filter.Q.value = 2.4
    filter.connect(output)

    const source = noiseSource(ctx)
    source.connect(filter)
    source.start()

    this.ctx = ctx
    this.nodes = { output, filter, source }
  }

  update(dt, { turbo }) {
    if (!this.nodes) return
    const target = turbo ? 1 : 0
    this.amount += (target - this.amount) * (1 - Math.exp(-6 * dt))

    const [low, high] = this.spec.sweep_hz
    const now = this.ctx.currentTime
    this.nodes.output.gain.setTargetAtTime(this.spec.gain * this.amount, now, 0.05)
    this.nodes.filter.frequency.setTargetAtTime(low + (high - low) * this.amount, now, 0.08)
  }

  dispose() {
    if (!this.nodes) return
    try { this.nodes.source.stop() } catch {}
    this.nodes.output.disconnect()
    this.nodes = null
  }
}

// One-shots: rocket launches, impacts, landings. Each builds a short throwaway graph.
export class OneShots {
  constructor(audio) {
    this.audio = audio
    this.nodes = true
  }

  attach(ctx, destination) {
    this.ctx = ctx
    this.destination = destination
  }

  update() {}

  // Noise burst plus a pitched-down sine thump: the crack and the punch.
  fire(spec) {
    if (!this.ctx) return
    const ctx = this.ctx
    const now = ctx.currentTime

    const burst = ctx.createGain()
    burst.gain.setValueAtTime(spec.gain, now)
    burst.gain.exponentialRampToValueAtTime(0.0001, now + 0.28)
    burst.connect(this.destination)

    const filter = ctx.createBiquadFilter()
    filter.type = "bandpass"
    filter.frequency.setValueAtTime(1800, now)
    filter.frequency.exponentialRampToValueAtTime(320, now + 0.25)
    filter.Q.value = 0.8
    filter.connect(burst)

    const source = noiseSource(ctx, { loop: false })
    source.connect(filter)
    source.start(now)
    source.stop(now + 0.3)

    const thump = ctx.createOscillator()
    thump.type = "sine"
    thump.frequency.setValueAtTime(spec.thump_hz, now)
    thump.frequency.exponentialRampToValueAtTime(spec.thump_hz * 0.45, now + 0.2)
    const thumpGain = ctx.createGain()
    thumpGain.gain.setValueAtTime(spec.gain * 0.9, now)
    thumpGain.gain.exponentialRampToValueAtTime(0.0001, now + 0.25)
    thump.connect(thumpGain).connect(this.destination)
    thump.start(now)
    thump.stop(now + 0.26)
  }

  // Impacts and landings scale with how hard the hit was.
  knock(spec, intensity) {
    if (!this.ctx || intensity <= 0) return
    const ctx = this.ctx
    const now = ctx.currentTime
    const strength = Math.min(intensity, 1)

    const gain = ctx.createGain()
    gain.gain.setValueAtTime(spec.gain * strength, now)
    gain.gain.exponentialRampToValueAtTime(0.0001, now + 0.18 + strength * 0.2)
    gain.connect(this.destination)

    const filter = ctx.createBiquadFilter()
    filter.type = "bandpass"
    filter.frequency.value = (spec.band_hz ?? spec.thump_hz ?? 220) * (0.7 + strength * 0.6)
    filter.Q.value = 1.4
    filter.connect(gain)

    const source = noiseSource(ctx, { loop: false })
    source.connect(filter)
    source.start(now)
    source.stop(now + 0.45)
  }

  dispose() {}
}
