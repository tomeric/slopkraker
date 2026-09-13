import * as THREE from "three"

const SKY = "#0e1116"

// How much the renderer is asked to do. Not game tuning -- the simulation is identical
// either way -- so it rides on the URL rather than in the spec.
//
// `low` exists because headless Chrome rasterises in software. A building of 1454 pieces
// costs it about two thirds of its frame in the shadow pass alone, and the fixed-step loop
// caps its substeps rather than running slow, so the SIMULATION quietly drops to 65% of
// real time. Every timed assertion in the suite then under-runs, and does it consistently
// enough to look like a physics change rather than a frame rate.
export const QUALITY = {
  high: { shadows: true, shadowMap: 2048, pixelRatio: 2 },
  low: { shadows: false, shadowMap: 512, pixelRatio: 1 }
}

export function qualityFor(name) {
  return QUALITY[name] || QUALITY.high
}

export function createRenderer(canvas, quality = QUALITY.high) {
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: quality.shadows, powerPreference: "high-performance" })
  renderer.setPixelRatio(Math.min(window.devicePixelRatio, quality.pixelRatio))
  renderer.shadowMap.enabled = quality.shadows
  // PCF rather than PCFSoft. The soft variant's extra taps land in the MAIN fragment
  // shader, over every lit pixel on screen, so its cost scales with how much of the frame
  // is lit rather than with how much geometry there is.
  renderer.shadowMap.type = THREE.PCFShadowMap
  return renderer
}

export function createScene(quality = QUALITY.high) {
  const scene = new THREE.Scene()
  scene.background = new THREE.Color(SKY)
  scene.fog = new THREE.Fog(SKY, 110, 280)

  const hemisphere = new THREE.HemisphereLight("#9fb8d0", "#2a2f36", 1.1)
  scene.add(hemisphere)

  const sun = new THREE.DirectionalLight("#fff4e0", 2.2)
  sun.position.set(48, 72, 36)
  sun.castShadow = quality.shadows
  sun.shadow.mapSize.set(quality.shadowMap, quality.shadowMap)
  sun.shadow.camera.near = 1
  sun.shadow.camera.far = 260
  const extent = 90
  sun.shadow.camera.left = -extent
  sun.shadow.camera.right = extent
  sun.shadow.camera.top = extent
  sun.shadow.camera.bottom = -extent
  sun.shadow.bias = -0.0008
  // A building is hundreds of coplanar boxes that all cast and all receive. Depth bias
  // alone cannot separate a face from the shadow of the face flush against it, so every
  // shared edge draws itself as a dark line and the wall reads as stacked boxes. normalBias
  // offsets the lookup along the surface normal, which is what that case actually needs.
  sun.shadow.normalBias = 0.06
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
