// Snapshots go out ~20Hz per client, so the wire format is flat arrays of rounded
// numbers rather than nested objects -- JSON of {x,y,z,w} objects 20x a second is pure
// overhead.
export const FLAG = { TURBO: 1 << 0, DRIFTING: 1 << 1, JETS: 1 << 2, BOOSTING: 1 << 3 }

const PRECISION = 1000

function round(value) {
  return Math.round(value * PRECISION) / PRECISION
}

export function encodeSnapshot(vehicle, key, tick, input) {
  const t = vehicle.body.translation()
  const r = vehicle.body.rotation()
  const v = vehicle.body.linvel()

  const wheels = []
  for (let i = 0; i < vehicle.wheelCount; i += 1) {
    wheels.push(
      round(vehicle.controller.wheelSuspensionLength(i) || 0),
      round(vehicle.controller.wheelRotation(i) || 0),
      round(vehicle.controller.wheelSteering(i) || 0)
    )
  }

  let flags = 0
  if (vehicle.turboActive) flags |= FLAG.TURBO
  if (vehicle.drifting) flags |= FLAG.DRIFTING
  if (vehicle.boostTime > 0) flags |= FLAG.BOOSTING
  if (vehicle.jetThrottle > 0) flags |= FLAG.JETS

  return {
    t: tick,
    vehicle: key,
    p: [ round(t.x), round(t.y), round(t.z) ],
    q: [ round(r.x), round(r.y), round(r.z), round(r.w) ],
    v: [ round(v.x), round(v.y), round(v.z) ],
    w: wheels,
    f: flags
  }
}
