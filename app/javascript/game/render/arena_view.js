import * as THREE from "three"

// Builds meshes straight from the Ruby arena spec. Nothing here decides geometry or
// placement -- it only renders what Ruby described.
export function buildArenaView(scene, arenaSpec) {
  const group = new THREE.Group()
  group.name = "arena"

  for (const body of arenaSpec.bodies) {
    group.add(staticMesh(body))
  }
  for (const prop of arenaSpec.props) {
    group.add(propMesh(prop))
  }

  scene.add(group)
  return group
}

function staticMesh(body) {
  const [w, h, d] = body.size
  const mesh = new THREE.Mesh(
    new THREE.BoxGeometry(w, h, d),
    new THREE.MeshStandardMaterial({
      color: body.colour,
      roughness: body.kind === "ground" ? 0.95 : 0.8,
      metalness: 0.02
    })
  )
  applyTransform(mesh, body)
  mesh.receiveShadow = true
  mesh.castShadow = body.kind !== "ground"
  mesh.name = body.name
  return mesh
}

function propMesh(prop) {
  const [w, h, d] = prop.size
  const mesh = new THREE.Mesh(
    new THREE.BoxGeometry(w, h, d),
    new THREE.MeshStandardMaterial({ color: prop.colour, roughness: 0.75, metalness: 0.05 })
  )
  applyTransform(mesh, prop)
  mesh.castShadow = true
  mesh.receiveShadow = true
  mesh.name = prop.name
  return mesh
}

function applyTransform(mesh, spec) {
  const [x, y, z] = spec.position
  mesh.position.set(x, y, z)
  const [qx, qy, qz, qw] = spec.rotation
  mesh.quaternion.set(qx, qy, qz, qw)
}
