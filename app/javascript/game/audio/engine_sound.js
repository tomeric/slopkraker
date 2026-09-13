import { noiseSource } from "game/audio/audio_engine"

const GEARS = 5

// Detuned sawtooths through a lowpass, plus a noise layer for induction roar. A fake
// gearbox makes the pitch climb and drop rather than sliding monotonically with speed,
// which is most of what makes an engine read as an engine.
export class EngineSound {
  constructor(spec, vehicleSpec) {
    this.spec = spec
    this.topSpeed = vehicleSpec.engine.top_speed
    this.revs = 0
    this.nodes = null
  }

  attach(ctx, destination) {
    const spec = this.spec
    const output = ctx.createGain()
    output.gain.value = 0
    output.connect(destination)

    const filter = ctx.createBiquadFilter()
    filter.type = "lowpass"
    filter.frequency.value = spec.lowpass_hz
    filter.Q.value = 0.7
    filter.connect(output)

    const oscillators = []
    for (let i = 0; i < spec.voices; i += 1) {
      const osc = ctx.createOscillator()
      osc.type = "sawtooth"
      osc.frequency.value = spec.idle_hz
      osc.detune.value = (i - (spec.voices - 1) / 2) * spec.detune
      osc.connect(filter)
      osc.start()
      oscillators.push(osc)
    }

    const rumble = noiseSource(ctx)
    const rumbleFilter = ctx.createBiquadFilter()
    rumbleFilter.type = "bandpass"
    rumbleFilter.frequency.value = 180
    rumbleFilter.Q.value = 0.9
    const rumbleGain = ctx.createGain()
    rumbleGain.gain.value = 0.35
    rumble.connect(rumbleFilter).connect(rumbleGain).connect(output)
    rumble.start()

    this.ctx = ctx
    this.nodes = { output, filter, oscillators, rumble, rumbleGain }
  }

  update(dt, { speed, throttle, grounded }) {
    if (!this.nodes) return

    const normalised = Math.min(Math.abs(speed) / this.topSpeed, 1)
    // Within-gear fraction: pitch climbs through a gear then drops on the shift.
    const through = normalised * GEARS
    const withinGear = through - Math.floor(through)

    // Idling revs sit at throttle; under load they follow the gear.
    const target = normalised < 0.02 ? 0.12 + throttle * 0.5 : 0.25 + 0.75 * withinGear
    this.revs += (target - this.revs) * (1 - Math.exp(-9 * dt))

    const spec = this.spec
    const frequency = spec.idle_hz + (spec.max_hz - spec.idle_hz) * this.revs
    const now = this.ctx.currentTime

    for (const osc of this.nodes.oscillators) {
      osc.frequency.setTargetAtTime(frequency, now, 0.03)
    }
    this.nodes.filter.frequency.setTargetAtTime(
      spec.lowpass_hz * (0.55 + 0.45 * this.revs), now, 0.05
    )

    // Silent parked with the throttle shut. A constant drone under everything else is
    // exactly what makes engine noise grating, and it was burying the rocket. It comes up
    // with the throttle or with road speed, whichever is doing more, and stays quieter in
    // the air where there is no load.
    const load = Math.min(Math.max(throttle, normalised * 1.3), 1)
    const airborne = grounded === 0 ? 0.75 : 1
    this.nodes.output.gain.setTargetAtTime(spec.gain * load * airborne, now, 0.05)
  }

  dispose() {
    if (!this.nodes) return
    for (const osc of this.nodes.oscillators) { try { osc.stop() } catch {} }
    try { this.nodes.rumble.stop() } catch {}
    this.nodes.output.disconnect()
    this.nodes = null
  }
}
