import { WORLD_GROUPS, PROP_GROUPS } from "game/physics/groups"
import { ColliderRegistry } from "game/sim/collider_registry"

// Builds the Rapier world from the Ruby arena spec. Static geometry gets parentless
// colliders (Rapier treats those as fixed); props get dynamic bodies so they can be
// knocked about and eventually broken.
export function createPhysicsWorld(RAPIER, spec) {
  const [gx, gy, gz] = spec.arena.gravity
  const world = new RAPIER.World({ x: gx, y: gy, z: gz })
  world.timestep = 1 / spec.rules.physics_hz

  const colliders = new ColliderRegistry()

  for (const body of spec.arena.bodies) {
    const [w, h, d] = body.size
    const [x, y, z] = body.position
    const [qx, qy, qz, qw] = body.rotation

    const desc = RAPIER.ColliderDesc.cuboid(w / 2, h / 2, d / 2)
      .setTranslation(x, y, z)
      .setRotation({ x: qx, y: qy, z: qz, w: qw })
      .setCollisionGroups(WORLD_GROUPS)
      .setFriction(body.friction)
      .setRestitution(body.restitution)
      .setActiveEvents(RAPIER.ActiveEvents.CONTACT_FORCE_EVENTS)
      .setContactForceEventThreshold(spec.rules.impact_force_threshold)

    const collider = world.createCollider(desc)
    colliders.set(collider.handle, { kind: body.kind, name: body.name, destructible: false, body: null })
  }

  const props = []
  for (const prop of spec.arena.props) {
    props.push(createProp(RAPIER, world, colliders, prop, spec.rules.impact_force_threshold))
  }

  return { world, colliders, props }
}

function createProp(RAPIER, world, colliders, prop, threshold) {
  const [w, h, d] = prop.size
  const [x, y, z] = prop.position
  const [qx, qy, qz, qw] = prop.rotation

  const body = world.createRigidBody(
    RAPIER.RigidBodyDesc.dynamic()
      .setTranslation(x, y, z)
      .setRotation({ x: qx, y: qy, z: qz, w: qw })
      .setLinearDamping(0.15)
      .setAngularDamping(0.3)
  )

  const collider = world.createCollider(
    RAPIER.ColliderDesc.cuboid(w / 2, h / 2, d / 2)
      .setMass(prop.mass)
      .setCollisionGroups(PROP_GROUPS)
      .setFriction(0.8)
      .setRestitution(0.1)
      .setActiveEvents(RAPIER.ActiveEvents.CONTACT_FORCE_EVENTS)
      .setContactForceEventThreshold(threshold),
    body
  )

  const entry = { spec: prop, body, collider, mesh: null, health: prop.health, broken: false }
  colliders.set(collider.handle, {
    kind: prop.kind, name: prop.name, destructible: true, body, prop: entry
  })
  return entry
}
