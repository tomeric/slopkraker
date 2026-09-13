// Faithful port of Game::TurboBar. The bar changes every frame so its state must live
// client-side, but the semantics are Ruby's and are covered by a parity system test.
const EPSILON = 1e-9

export class TurboBar {
  constructor({ capacity, recharge_rate, recharge_delay }) {
    this.capacity = capacity
    this.rechargeRate = recharge_rate
    this.rechargeDelay = recharge_delay
    this.level = capacity
    this.sinceDraw = Infinity
  }

  get full() { return this.level >= this.capacity - EPSILON }
  get empty() { return this.level <= EPSILON }
  get fraction() { return this.capacity === 0 ? 0 : this.level / this.capacity }

  draw(amount) {
    if (amount > this.level) return false
    this.level -= amount
    this.sinceDraw = 0
    return true
  }

  update(dt) {
    this.sinceDraw += dt
    const idle = this.sinceDraw - this.rechargeDelay
    if (idle <= 0) return this.level

    const charged = this.level + this.rechargeRate * Math.min(idle, dt)
    this.level = charged >= this.capacity - EPSILON ? this.capacity : charged
    return this.level
  }
}
