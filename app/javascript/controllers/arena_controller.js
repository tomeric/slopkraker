import { Controller } from "@hotwired/stimulus"

// The engine is imported dynamically: controllers/index.js eager-loads every controller
// on every page, and a top-level three.js import would parse ~4MB app-wide.
export default class extends Controller {
  static targets = ["canvas", "status", "spec", "mute", "muteIcon", "muteLabel"]
  static values = { playerId: String, match: String, world: String, quality: String }

  async connect() {
    const token = (this.bootToken = Symbol("boot"))

    const { GameEngine } = await import("game/engine")
    if (this.bootToken !== token) return

    this.engine = new GameEngine({
      canvas: this.canvasTarget,
      root: this.element,
      spec: JSON.parse(this.specTarget.textContent),
      playerId: this.playerIdValue,
      match: this.matchValue,
      world: this.worldValue,
      quality: this.qualityValue,
      vehicleKey: new URLSearchParams(window.location.search).get("vehicle") || "monster_truck",
      onStatus: (message) => this.showStatus(message),
      onMuteChange: (muted) => this.showMuted(muted)
    })

    try {
      await this.engine.start()
    } catch (error) {
      this.showStatus(`Failed to start: ${error.message}`)
      throw error
    }

    // connect() is sync but start() is not; a fast Turbo visit can disconnect mid-boot,
    // which would otherwise leave a live render loop drawing into a detached canvas.
    if (this.bootToken !== token) {
      this.engine.dispose()
      this.engine = null
    }
  }

  toggleMute() {
    this.showMuted(this.engine?.toggleMute())
  }

  showMuted(muted) {
    if (!this.hasMuteTarget) return

    this.muteTarget.setAttribute("aria-pressed", String(Boolean(muted)))
    if (this.hasMuteIconTarget) this.muteIconTarget.textContent = muted ? "🔇" : "🔊"
    if (this.hasMuteLabelTarget) this.muteLabelTarget.textContent = muted ? "Muted" : "Sound on"
  }

  disconnect() {
    this.bootToken = null
    this.engine?.dispose()
    this.engine = null
  }

  showStatus(message) {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent = message || ""
    this.statusTarget.hidden = !message
  }
}
