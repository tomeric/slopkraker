import * as THREE from "three"

// How much the renderer is asked to do. Not game tuning -- the simulation is identical
// either way -- so it rides on the URL rather than in the spec.
//
// `low` exists because headless Chrome rasterises in software. A building of 1454 pieces
// costs it about two thirds of its frame in the shadow pass alone, and the fixed-step loop
// caps its substeps rather than running slow, so the SIMULATION quietly drops to 65% of
// real time. Every timed assertion in the suite then under-runs, and does it consistently
// enough to look like a physics change rather than a frame rate.
// `textures` is the surface detail of §2: the bond, the courses, the planks, painted at
// boot. It is off at `low` for the same reason the shadows are -- it is fragment cost, and
// the timing assertions are calibrated without it.
export const QUALITY = {
  high: { shadows: true, shadowMap: 2048, pixelRatio: 2, textures: true },
  low: { shadows: false, shadowMap: 512, pixelRatio: 1, textures: false }
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

// The world is lit by `sky` -- one of rules.sky's entries, day or night, chosen by the URL.
// At high quality the sky is a gradient texture drawn behind everything and filtered into
// an environment map, so steel reflects a horizon and glass gets a highlight; at low it
// is the horizon colour and nothing more, so the suite's fragment cost is what it was.
export function createScene(quality, sky, renderer = null) {
  const scene = new THREE.Scene()
  const horizon = new THREE.Color(sky.horizon)
  scene.fog = new THREE.Fog(horizon, sky.fog[0], sky.fog[1])

  if (quality.textures && renderer) {
    const gradient = skyTexture(sky)
    scene.background = gradient
    const pmrem = new THREE.PMREMGenerator(renderer)
    // fromEquirectangular returns the WebGLRenderTarget, not just its texture. Three only
    // frees the target's framebuffer when the TARGET is disposed -- disposing the texture
    // alone deletes the GL texture but leaks the framebuffer -- so the target is kept here
    // and disposed alongside it in disposeScene.
    const target = pmrem.fromEquirectangular(gradient)
    scene.environment = target.texture
    scene.userData.environmentTarget = target
    pmrem.dispose()
  } else {
    scene.background = horizon
  }

  const [ skyColour, groundColour, intensity ] = sky.hemisphere
  scene.add(new THREE.HemisphereLight(skyColour, groundColour, intensity))

  const sun = new THREE.DirectionalLight(sky.sun, sky.sun_intensity)
  sun.position.set(...sky.sun_direction)
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

// The sky as a tiny equirectangular gradient: zenith at the top, horizon across the
// middle, ground below. Sixteen by sixty-four texels is plenty for a gradient, and it is
// the one texture the environment map is filtered from.
export function skyTexture(sky) {
  const width = 16
  const height = 64
  const data = new Uint8Array(width * height * 4)
  const zenith = new THREE.Color(sky.zenith)
  const horizon = new THREE.Color(sky.horizon)
  const ground = new THREE.Color(sky.ground)
  const colour = new THREE.Color()
  for (let y = 0; y < height; y += 1) {
    // Row 0 is the bottom of the image (DataTexture, flipY false): ground up to horizon
    // in the lower half, horizon up to zenith in the upper.
    const t = y / (height - 1)
    if (t < 0.5) colour.copy(ground).lerp(horizon, Math.pow(t * 2, 0.6))
    else colour.copy(horizon).lerp(zenith, Math.pow((t - 0.5) * 2, 0.8))
    // The texture is sRGB and Color's channels are linear, so write the sRGB bytes that
    // getHex encodes rather than the linear channels scaled by 255.
    const hex = colour.getHex()
    for (let x = 0; x < width; x += 1) {
      const i = (y * width + x) * 4
      data[i] = (hex >> 16) & 255
      data[i + 1] = (hex >> 8) & 255
      data[i + 2] = hex & 255
      data[i + 3] = 255
    }
  }
  const texture = new THREE.DataTexture(data, width, height)
  texture.mapping = THREE.EquirectangularReflectionMapping
  texture.colorSpace = THREE.SRGBColorSpace
  texture.magFilter = THREE.LinearFilter
  texture.minFilter = THREE.LinearFilter
  texture.needsUpdate = true
  return texture
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
  if (scene.background?.isTexture) scene.background.dispose()
  // Disposing the render target also deletes the GL texture it owns (WebGLRenderTargets
  // deletes every texture in `renderTarget.textures` when the target itself is disposed),
  // so this alone reclaims what fromEquirectangular allocated -- the framebuffer included.
  scene.userData.environmentTarget?.dispose()
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
