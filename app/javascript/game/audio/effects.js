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
  // The motor catching: noise swept UPWARD through a bandpass with a short attack. The
  // launch thump sweeps down, so a single shot reads as two distinct events rather than
  // as the same sound played twice.
  ignite(spec) {
    if (!this.ctx) return
    const ctx = this.ctx
    const now = ctx.currentTime
    const [from, to] = spec.sweep_hz

    const burst = ctx.createGain()
    // Ramped up from near-silence rather than set: an exponential ramp cannot start at 0.
    burst.gain.setValueAtTime(0.0001, now)
    burst.gain.exponentialRampToValueAtTime(spec.gain, now + 0.06)
    burst.gain.exponentialRampToValueAtTime(0.0001, now + 0.45)
    burst.connect(this.destination)

    const filter = ctx.createBiquadFilter()
    filter.type = "bandpass"
    filter.frequency.setValueAtTime(from, now)
    filter.frequency.exponentialRampToValueAtTime(to, now + 0.45)
    // Wide rather than narrow: a tight band whistles, and what this wants is body.
    filter.Q.value = 1.0
    filter.connect(burst)

    const source = noiseSource(ctx, { loop: false })
    source.connect(filter)
    source.start(now)
    source.stop(now + 0.6)

    // A low swell under the hiss. Without it the sweep is all air and no motor -- this is
    // the part you feel rather than hear.
    const body = ctx.createOscillator()
    body.type = "sawtooth"
    body.frequency.setValueAtTime(from * 0.32, now)
    body.frequency.exponentialRampToValueAtTime(from * 0.75, now + 0.35)
    const bodyGain = ctx.createGain()
    bodyGain.gain.setValueAtTime(0.0001, now)
    bodyGain.gain.exponentialRampToValueAtTime(spec.gain * 0.45, now + 0.08)
    bodyGain.gain.exponentialRampToValueAtTime(0.0001, now + 0.5)

    const warmth = ctx.createBiquadFilter()
    warmth.type = "lowpass"
    warmth.frequency.value = 900
    body.connect(warmth).connect(bodyGain).connect(this.destination)
    body.start(now)
    body.stop(now + 0.55)
  }

  // The motor burning, held for as long as it burns -- unlike everything else here, which
  // is a one-shot. The caller keeps the handle and stops it when the rocket dies, so a
  // rocket cannot leave its own thrust hanging in the mix after it has gone.
  //
  // Deliberately one voice and not two: a low oscillator under the hiss read as a separate
  // sound playing alongside it rather than as body underneath it.
  thrust(spec) {
    if (!this.ctx) return null
    const ctx = this.ctx
    const now = ctx.currentTime

    const hiss = ctx.createGain()
    hiss.gain.setValueAtTime(0.0001, now)
    hiss.gain.exponentialRampToValueAtTime(spec.gain, now + 0.08)
    hiss.connect(this.destination)

    const filter = ctx.createBiquadFilter()
    filter.type = "bandpass"
    filter.frequency.value = spec.band_hz
    filter.Q.value = 0.6
    filter.connect(hiss)

    const source = noiseSource(ctx, { loop: true })
    source.connect(filter)
    source.start(now)

    return {
      stop() {
        const t = ctx.currentTime
        hiss.gain.cancelScheduledValues(t)
        hiss.gain.setValueAtTime(Math.max(hiss.gain.value, 0.0001), t)
        hiss.gain.exponentialRampToValueAtTime(0.0001, t + 0.12)
        source.stop(t + 0.15)
      }
    }
  }

  // Bigger and longer than a knock: a crack of noise collapsing into a low boom. Scaled by
  // how much the blast was worth, so a glancing one does not sound like a direct hit.
  blast(spec, intensity = 1) {
    if (!this.ctx) return
    const ctx = this.ctx
    const now = ctx.currentTime
    const level = spec.gain * Math.min(Math.max(intensity, 0.25), 1)

    const crack = ctx.createGain()
    crack.gain.setValueAtTime(level, now)
    crack.gain.exponentialRampToValueAtTime(0.0001, now + 0.6)
    crack.connect(this.destination)

    const filter = ctx.createBiquadFilter()
    filter.type = "lowpass"
    filter.frequency.setValueAtTime(2600, now)
    filter.frequency.exponentialRampToValueAtTime(180, now + 0.5)
    filter.connect(crack)

    const source = noiseSource(ctx, { loop: false })
    source.connect(filter)
    source.start(now)
    source.stop(now + 0.65)

    const boom = ctx.createOscillator()
    boom.type = "sine"
    boom.frequency.setValueAtTime(spec.boom_hz, now)
    boom.frequency.exponentialRampToValueAtTime(spec.boom_hz * 0.35, now + 0.5)
    const boomGain = ctx.createGain()
    boomGain.gain.setValueAtTime(level * 1.1, now)
    boomGain.gain.exponentialRampToValueAtTime(0.0001, now + 0.55)
    boom.connect(boomGain).connect(this.destination)
    boom.start(now)
    boom.stop(now + 0.6)
  }

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
