// Procedural Web Audio -- no sample files to source, ship or cache. Everything is
// synthesised from oscillators and filtered noise.
//
// The context starts suspended under browser autoplay policy and can only be resumed
// from a real user gesture, so it is created lazily on the first key or pointer press.
// Chrome also caps contexts per page and does not reclaim them on navigation, so this is
// a module-level singleton shared across Turbo visits rather than one per engine.
let shared = null

export function audioContext() {
  if (shared) return shared
  const Ctor = window.AudioContext || window.webkitAudioContext
  if (!Ctor) return null

  try {
    shared = new Ctor()
  } catch {
    shared = null
  }
  return shared
}

export class AudioEngine {
  constructor(element, { masterGain = 0.75 } = {}) {
    this.element = element
    this.ctx = null
    this.master = null
    this.voices = []
    this.enabled = false
    this.masterGain = masterGain
    // Remembered per browser: having to re-mute on every reload is its own annoyance.
    this.muted = readMuted()

    this.unlock = () => this.resume()
    window.addEventListener("keydown", this.unlock)
    element.addEventListener("pointerdown", this.unlock)
  }

  resume() {
    const ctx = audioContext()
    if (!ctx) return

    if (!this.ctx) {
      this.ctx = ctx
      this.master = ctx.createGain()
      this.master.gain.value = this.muted ? 0 : this.masterGain
      this.master.connect(ctx.destination)
      this.enabled = true
      for (const voice of this.voices) voice.attach(ctx, this.master)
    }

    if (ctx.state === "suspended") ctx.resume().catch(() => {})
  }

  setMuted(muted) {
    this.muted = muted
    writeMuted(muted)
    if (this.master) this.master.gain.value = muted ? 0 : this.masterGain
    return this.muted
  }

  toggleMute() {
    return this.setMuted(!this.muted)
  }

  add(voice) {
    this.voices.push(voice)
    if (this.ctx) voice.attach(this.ctx, this.master)
    return voice
  }

  update(dt, telemetry) {
    if (!this.enabled) return
    for (const voice of this.voices) voice.update(dt, telemetry)
  }

  dispose() {
    window.removeEventListener("keydown", this.unlock)
    this.element.removeEventListener("pointerdown", this.unlock)

    for (const voice of this.voices) voice.dispose()
    this.voices = []
    this.master?.disconnect()
    // Suspend rather than close: a closed AudioContext can never be reopened, and this
    // one outlives the engine.
    if (this.ctx?.state === "running") this.ctx.suspend().catch(() => {})
    this.ctx = null
    this.enabled = false
  }
}

// One shared noise buffer -- regenerating it per effect is pure waste.
let noiseBuffer = null

export function noise(ctx) {
  if (!noiseBuffer || noiseBuffer.sampleRate !== ctx.sampleRate) {
    const length = ctx.sampleRate * 2
    noiseBuffer = ctx.createBuffer(1, length, ctx.sampleRate)
    const data = noiseBuffer.getChannelData(0)
    for (let i = 0; i < length; i += 1) data[i] = Math.random() * 2 - 1
  }
  return noiseBuffer
}

export function noiseSource(ctx, { loop = true } = {}) {
  const source = ctx.createBufferSource()
  source.buffer = noise(ctx)
  source.loop = loop
  return source
}

const MUTE_KEY = "carnavalskraker:muted"

// Wrapped: storage throws outright in a private window or with site data blocked, and a
// muted preference is never worth failing a page load over.
function readMuted() {
  try {
    return window.localStorage.getItem(MUTE_KEY) === "true"
  } catch {
    return false
  }
}

function writeMuted(muted) {
  try {
    window.localStorage.setItem(MUTE_KEY, String(muted))
  } catch {
    // Ignore: the preference simply will not persist.
  }
}
