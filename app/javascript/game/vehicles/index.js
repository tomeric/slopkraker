import { Vehicle } from "game/vehicles/vehicle"
import { MonsterTruck } from "game/vehicles/monster_truck"
import { Buggy } from "game/vehicles/buggy"

const REGISTRY = { monster_truck: MonsterTruck, buggy: Buggy }

export function buildVehicle(key, options) {
  const Klass = REGISTRY[key] || Vehicle
  return new Klass(options)
}

export function vehicleKeys(spec) {
  return Object.keys(spec.vehicles)
}
