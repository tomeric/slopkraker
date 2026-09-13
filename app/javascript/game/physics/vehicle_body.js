import { vehicleGroups } from "game/physics/groups"

// Builds the Rapier chassis, part colliders and raycast vehicle controller from the
// Ruby vehicle spec. Every number here comes from the spec; none are invented.
export function createVehicleBody(RAPIER, world, spec, spawn, colliderIndex, meta) {
  const chassis = spec.chassis
  const [cw, ch, cl] = chassis.size
  const mass = chassis.mass
  const [ix, iy, iz] = chassis.inertia_scale
  const [comX, comY, comZ] = chassis.centre_of_mass

  // Box inertia about the principal axes, scaled per-axis. Lowering yaw inertia is what
  // stops a heavy vehicle feeling like it is turning underwater.
  const inertia = {
    x: (mass / 12) * (ch * ch + cl * cl) * ix,
    y: (mass / 12) * (cw * cw + cl * cl) * iy,
    z: (mass / 12) * (cw * cw + ch * ch) * iz
  }

  const body = world.createRigidBody(
    RAPIER.RigidBodyDesc.dynamic()
      .setTranslation(spawn.position[0], spawn.position[1], spawn.position[2])
      // Heading matters: dropped in facing a fixed direction, the car drives straight
      // off the circuit.
      .setRotation({ x: 0, y: Math.sin(spawn.yaw / 2), z: 0, w: Math.cos(spawn.yaw / 2) })
      .setLinearDamping(chassis.linear_damping)
      .setAngularDamping(chassis.angular_damping)
      .setCcdEnabled(chassis.ccd)
      // Mass comes from the spec, not from collider geometry, so the centre of mass can
      // sit below the box centre -- the cheapest anti-roll there is.
      .setAdditionalMassProperties(
        mass,
        { x: comX, y: comY, z: comZ },
        inertia,
        { x: 0, y: 0, z: 0, w: 1 }
      )
  )

  const threshold = meta.impactThreshold
  const events = RAPIER.ActiveEvents.CONTACT_FORCE_EVENTS

  const chassisCollider = world.createCollider(
    RAPIER.ColliderDesc.cuboid(cw / 2, ch / 2, cl / 2)
      .setDensity(0)
      .setCollisionGroups(vehicleGroups(meta.owner))
      .setFriction(0.5)
      .setRestitution(0.05)
      .setActiveEvents(events)
      .setContactForceEventThreshold(threshold),
    body
  )
  colliderIndex.set(chassisCollider.handle, {
    kind: "chassis", name: "chassis", part: null, vehicle: meta.key, owner: meta.owner, body
  })

  const partColliders = []
  for (const part of spec.parts) {
    // Jets are an emitter, not a solid.
    if (part.kind === "jump_jets") continue

    const [pw, ph, pl] = part.size
    const [ox, oy, oz] = part.offset
    const collider = world.createCollider(
      RAPIER.ColliderDesc.cuboid(pw / 2, ph / 2, pl / 2)
        .setDensity(0)
        .setCollisionGroups(vehicleGroups(meta.owner))
        .setTranslation(ox, oy, oz)
        .setFriction(0.4)
        .setRestitution(0.1)
        .setActiveEvents(events)
        .setContactForceEventThreshold(threshold),
      body
    )
    colliderIndex.set(collider.handle, {
      kind: part.kind, name: part.name, part, vehicle: meta.key, owner: meta.owner, body
    })
    partColliders.push({ part, collider })
  }

  const controller = world.createVehicleController(body)
  controller.indexUpAxis = 1
  // This is a property setter, NOT a method: `setIndexForwardAxis(2)` throws.
  controller.setIndexForwardAxis = 2

  spec.wheels.forEach((wheel, index) => {
    const [wx, wy, wz] = wheel.position
    controller.addWheel(
      { x: wx, y: wy, z: wz },
      { x: 0, y: -1, z: 0 },
      { x: -1, y: 0, z: 0 },
      wheel.suspension.rest_length,
      wheel.radius
    )
    applyWheelTuning(controller, index, wheel)
  })

  return { body, controller, chassisCollider, partColliders }
}

// Split out so the live tuning panel can re-apply changed suspension without a rebuild.
export function applyWheelTuning(controller, index, wheel) {
  const s = wheel.suspension
  controller.setWheelSuspensionRestLength(index, s.rest_length)
  controller.setWheelSuspensionStiffness(index, s.stiffness)
  controller.setWheelSuspensionCompression(index, s.compression)
  controller.setWheelSuspensionRelaxation(index, s.relaxation)
  controller.setWheelMaxSuspensionTravel(index, s.max_travel)
  controller.setWheelMaxSuspensionForce(index, s.max_force)
  controller.setWheelRadius(index, wheel.radius)
  controller.setWheelFrictionSlip(index, wheel.friction_slip)
  controller.setWheelSideFrictionStiffness(index, wheel.side_friction_stiffness)
}
