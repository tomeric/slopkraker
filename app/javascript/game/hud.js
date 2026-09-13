const REFRESH_HZ = 12

export class Hud {
  constructor(root) {
    this.speed = root.querySelector('[data-arena-target="speed"]')
    this.turboFill = root.querySelector('[data-arena-target="turboFill"]')
    this.vehicleName = root.querySelector('[data-arena-target="vehicleName"]')
    this.elapsed = 0
  }

  // Throttled: touching the DOM at 120Hz costs more than the whole physics step.
  update(dt, vehicle) {
    this.elapsed += dt
    if (this.elapsed < 1 / REFRESH_HZ) return
    this.elapsed = 0

    if (this.speed) {
      // Planar speed: a drifting car is still travelling fast even when its forward
      // component has collapsed.
      this.speed.textContent = Math.round(vehicle.planarSpeed * 3.6)
    }
    if (this.turboFill) {
      const fraction = vehicle.turboBar.fraction
      this.turboFill.style.transform = `scaleX(${fraction})`
      this.turboFill.style.backgroundColor = fraction < 0.15 ? "#e2574c" : "#f2c014"
    }
    if (this.vehicleName) {
      this.vehicleName.textContent = vehicle.spec.name
    }
  }
}
