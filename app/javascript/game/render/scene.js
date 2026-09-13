import * as THREE from "three"

const SKY = "#0e1116"

export function createRenderer(canvas) {
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, powerPreference: "high-performance" })
  renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2))
  renderer.shadowMap.enabled = true
  renderer.shadowMap.type = THREE.PCFSoftShadowMap
  return renderer
}

export function createScene() {
  const scene = new THREE.Scene()
  scene.background = new THREE.Color(SKY)
  scene.fog = new THREE.Fog(SKY, 110, 280)

  const hemisphere = new THREE.HemisphereLight("#9fb8d0", "#2a2f36", 1.1)
  scene.add(hemisphere)

  const sun = new THREE.DirectionalLight("#fff4e0", 2.2)
  sun.position.set(48, 72, 36)
  sun.castShadow = true
  sun.shadow.mapSize.set(2048, 2048)
  sun.shadow.camera.near = 1
  sun.shadow.camera.far = 260
  const extent = 90
  sun.shadow.camera.left = -extent
  sun.shadow.camera.right = extent
  sun.shadow.camera.top = extent
  sun.shadow.camera.bottom = -extent
  sun.shadow.bias = -0.0008
  scene.add(sun)
  scene.add(sun.target)

  return { scene, sun }
}

export function createCamera(aspect) {
  const camera = new THREE.PerspectiveCamera(70, aspect, 0.1, 600)
  camera.position.set(0, 8, -16)
  camera.lookAt(0, 0, 0)
  return camera
}

// Three.js does not free GPU memory on its own. Every Turbo visit builds a new scene,
// and browsers cap live WebGL contexts (~16 in Chrome) before silently killing the
// oldest -- which shows up much later as "the game stopped rendering".
export function disposeScene(scene) {
  scene.traverse((object) => {
    if (object.geometry) object.geometry.dispose()
    const material = object.material
    if (!material) return
    const materials = Array.isArray(material) ? material : [material]
    for (const entry of materials) {
      for (const key of Object.keys(entry)) {
        const value = entry[key]
        if (value && value.isTexture) value.dispose()
      }
      entry.dispose()
    }
  })
  scene.clear()
}
