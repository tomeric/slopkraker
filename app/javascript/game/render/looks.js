import * as THREE from "three"

// How a material is DRAWN: the brick bond, the tile courses, the planks, painted once at
// boot into textures from the numbers Ruby ships in `materials[*].look`. No image files,
// no downloads -- every pixel comes from the spec, the same on every machine.
//
// Textures rather than a pattern evaluated per fragment, for three reasons. A mortar line
// is a few millimetres wide: evaluated per fragment it aliases into shimmer at thirty
// metres unless filtered by hand, where a texture's mipmaps filter it for free. The normal
// map is the same picture, and a per-fragment pattern would need its own derivative
// machinery for the relief. And headless Chrome's software rasteriser runs the suite: a
// texture fetch is the cheapest thing a fragment can do.
//
// The albedo is painted in VALUE space -- light and nearly neutral -- because the colour
// is the palette's, applied per instance (PieceMeshes): tint = palette[role] x jitter x
// damage shade. One pool, one texture and one draw call serve every building whatever its
// palette.

// Metres of surface one texture covers, and texels per tile edge (a texel is 4 mm). Shape
// constants of the drawing, not tuning: everything that decides WHAT is drawn arrives in
// the spec. If the repetition ever shows on tiles or planks, the tile grows to 4 m at four
// times the memory.
export const TILE = 2
export const SIZE = 512
// Texels per metre.
const PX = SIZE / TILE
// Patterns this file paints. Ruby's Material::PATTERNS is the same list, and
// materials_test holds every material's look to it.
export const PATTERNS = [ "brick", "tiles", "planks", "plaster", "concrete", "glass", "leaves" ]

export class Looks {
  constructor(materials, quality, renderer = null) {
    this.materials = materials
    this.enabled = Boolean(quality.textures)
    this.anisotropy = renderer?.capabilities?.getMaxAnisotropy?.() ?? 1
    this.textures = new Map()
    this.lawnTexture = null
    if (!this.enabled) return

    for (const [ name, spec ] of Object.entries(materials)) {
      const look = spec.look
      if (!look || !PATTERNS.includes(look.pattern)) continue
      this.textures.set(name, paint(look, spec, this.anisotropy))
    }
  }

  has(name) {
    return this.textures.has(name)
  }

  // Dresses a MeshStandardMaterial in `name`'s look: colour white, because the tint rides
  // on the instance; the three maps; and, unless `metres` is off, the vertex chunk that
  // maps texture coordinates from metres along the surface rather than from the cube's
  // own uv. Glass keeps per-cell uv: its frame is drawn round each pane.
  apply(material, name, { metres = true } = {}) {
    const look = this.textures.get(name)
    if (!look) return material

    material.color.set("#ffffff")
    material.map = look.map
    material.normalMap = look.normalMap
    material.normalScale.set(look.relief, look.relief)
    material.roughnessMap = look.roughnessMap
    // The map carries the roughness; the scalar would multiply it a second time.
    material.roughness = 1
    if (look.alpha) {
      material.transparent = true
      material.opacity = 1
    }
    if (metres && look.metres) installMetresUv(material)
    material.needsUpdate = true
    return material
  }

  // A material for a slab of `name` falling on a mesh of its own: the look if there is
  // one, otherwise flat; DoubleSide because a slab is seen from every side as it tumbles.
  // Colour white here too -- the caller sets the tint the slab fell with.
  slabMaterial(name) {
    const spec = this.materials[name] || {}
    const material = new THREE.MeshStandardMaterial({
      color: "#ffffff", roughness: spec.roughness ?? 0.85, metalness: spec.metalness ?? 0.05,
      transparent: (spec.opacity ?? 1) < 1, opacity: spec.opacity ?? 1, side: THREE.DoubleSide
    })
    return this.apply(material, name)
  }

  // The lawn's texture, painted on first use from `look` (`rules.gardens.look`): a leafy
  // speckle with no relief. Null when textures are off, or when no look shipped at all.
  lawn(look) {
    if (!this.enabled || !look) return null
    if (!this.lawnTexture) {
      const albedo = canvas()
      leaves(albedo.getContext("2d"), null, null, look, {})
      this.lawnTexture = texture(albedo, this.anisotropy)
      this.lawnTexture.colorSpace = THREE.SRGBColorSpace
    }
    return this.lawnTexture
  }

  readout() {
    return { enabled: this.enabled, tile: TILE, size: SIZE, textured: [ ...this.textures.keys() ].sort() }
  }

  dispose() {
    for (const look of this.textures.values()) {
      look.map.dispose()
      look.normalMap.dispose()
      look.roughnessMap.dispose()
    }
    this.textures.clear()
    this.lawnTexture?.dispose()
    this.lawnTexture = null
  }
}

// --- the shader chunk ----------------------------------------------------------------

// Texture coordinates in METRES along the surface, continuous across the cells of a wall.
//
// Each instance carries its cell's offset along its surface in metres (`cellUV`, written
// beside the instance matrix), and the instance matrix's column lengths are the cell's
// size -- cellMatrix composes T * R * S with scale (width, height, thickness), so the unit
// cube's local position in [-0.5, 0.5] becomes metres from the cell's corner. A face whose
// object-space normal is +-z is one of the wall's two faces: it maps (x, y) + cellUV, so
// the bond runs on into the neighbouring cell and the courses stay level along the row. A
// face whose normal is +-x or +-y is a cross-section exposed where a cell is missing: it
// maps the cell's own depth, so a hole shows brick ends rather than a stretched face.
//
// A plain Mesh (a falling slab) has no instanceMatrix and no cellUV: its scale comes off
// modelMatrix and the attribute reads WebGL's default of zero, so the slab keeps the bond
// it was cut with, starting from its own corner.
const METRES_UV = /* glsl */`
vec3 metresScale;
#ifdef USE_INSTANCING
  metresScale = vec3( length( instanceMatrix[ 0 ].xyz ), length( instanceMatrix[ 1 ].xyz ), length( instanceMatrix[ 2 ].xyz ) );
#else
  metresScale = vec3( length( modelMatrix[ 0 ].xyz ), length( modelMatrix[ 1 ].xyz ), length( modelMatrix[ 2 ].xyz ) );
#endif
vec3 metres3 = ( position + 0.5 ) * metresScale;
vec3 metresN = abs( normal );
vec2 metres;
if ( metresN.z >= metresN.x && metresN.z >= metresN.y ) metres = metres3.xy + cellUV;
else if ( metresN.x >= metresN.y ) metres = metres3.zy;
else metres = metres3.xz;
vec2 metresUv = metres / TILE_METRES;
#if defined( USE_UV ) || defined( USE_ANISOTROPY )
  vUv = metresUv;
#endif
#ifdef USE_MAP
  vMapUv = metresUv;
#endif
#ifdef USE_NORMALMAP
  vNormalMapUv = metresUv;
#endif
#ifdef USE_ROUGHNESSMAP
  vRoughnessMapUv = metresUv;
#endif
`

function installMetresUv(material) {
  material.onBeforeCompile = (shader) => {
    shader.vertexShader = `attribute vec2 cellUV;\n#define TILE_METRES ${TILE.toFixed(1)}\n` +
      shader.vertexShader.replace("#include <uv_vertex>", METRES_UV)
  }
  // Every material dressed this way compiles the same chunk, so they share programs
  // where their other defines agree.
  material.customProgramCacheKey = () => "metres-uv"
}

// --- painting --------------------------------------------------------------------------

function paint(look, spec, anisotropy) {
  const albedo = canvas()
  const height = canvas()
  const rough = canvas()
  PAINTERS[look.pattern](albedo.getContext("2d"), height.getContext("2d"), rough.getContext("2d"), look, spec)

  const map = texture(albedo, anisotropy)
  map.colorSpace = THREE.SRGBColorSpace
  return {
    map,
    normalMap: texture(normalFrom(height), anisotropy),
    roughnessMap: texture(rough, anisotropy),
    relief: look.relief ?? 0,
    alpha: look.pattern === "glass",
    // Glass maps per cell -- its frame goes round each pane -- everything else in metres.
    metres: look.pattern !== "glass"
  }
}

function canvas() {
  const element = document.createElement("canvas")
  element.width = SIZE
  element.height = SIZE
  return element
}

function texture(source, anisotropy) {
  const result = new THREE.CanvasTexture(source)
  result.wrapS = THREE.RepeatWrapping
  result.wrapT = THREE.RepeatWrapping
  result.anisotropy = anisotropy
  result.needsUpdate = true
  return result
}

// A CSS colour: `hex` with its lightness multiplied by `factor`.
function shade(hex, factor) {
  const value = parseInt(hex.slice(1), 16)
  const channel = (shift) => Math.max(0, Math.min(255, Math.round(((value >> shift) & 255) * factor)))
  return `rgb(${channel(16)}, ${channel(8)}, ${channel(0)})`
}

function grey(level) {
  const v = Math.max(0, Math.min(255, Math.round(level * 255)))
  return `rgb(${v}, ${v}, ${v})`
}

function fill(ctx, colour) {
  if (!ctx) return
  ctx.fillStyle = colour
  ctx.fillRect(0, 0, SIZE, SIZE)
}

function box(ctx, colour, x, y, w, h) {
  if (!ctx) return
  ctx.fillStyle = colour
  ctx.fillRect(x, y, w, h)
}

// Deterministic in [0, 1): the same texel on every machine, because two players have to
// see the same wall.
function noise(a, b, c = 0) {
  let h = (a * 374761393 + b * 668265263 + c * 2246822519) | 0
  h = Math.imul(h ^ (h >>> 13), 1274126177)
  return ((h ^ (h >>> 16)) >>> 0) / 4294967296
}

// Whole units per tile along an axis whose rows all start in the same place: bricks along
// a course, tiles across one, boards across a door. Whole units are what makes the tile
// seamless in GEOMETRY -- a unit is never cut in half at the edge -- and a 210 mm brick
// comes out 200 mm for it. Nobody measures.
function perTile(metres) {
  return Math.max(1, Math.round(TILE / metres))
}

// The same, for the axis a HALF OFFSET alternates along: a running bond's courses, a roof's
// tile courses. Rounded to an EVEN count, because seamless geometry is only half of a
// seamless tile and the other half is bond PARITY. The offset alternates on `r % 2`, so an
// odd count puts the tile's last row and the next tile's first row both at offset zero:
// their perpends line up and the wall carries a straight joint the whole way across at every
// tile boundary. Brick's 65 mm courses come out 30 to the two metres rather than 31 --
// 66.7 mm, and nobody measures that either.
function perTileEven(metres) {
  return Math.max(2, Math.round(TILE / metres / 2) * 2)
}

// Which unit's jitter a column draws, wrapped into the tile.
//
// A half-offset course runs from `c = -1` so the tile's left edge is covered by a unit
// rather than by bare joint. That unit is the SAME unit as the one at `c = count - 1`:
// once the texture wraps they are the left and right halves of one brick lying across the
// seam. Indexed by their own `c` they are drawn two different lightnesses, and the step
// between them -- about 7% at brick's variation -- is a faint vertical line at the same x
// on every odd course, every TILE metres across every wall in the world. Wrapping the
// index is what makes the two halves one brick.
function wrapped(c, count) {
  return ((c % count) + count) % count + 1
}

// Running bond: courses of `unit[1]`, bricks of `unit[0]`, every other course offset by
// half a brick, joints recessed and darker, each brick its own lightness.
function brick(ctx, hctx, rctx, look, spec) {
  const courses = perTileEven(look.unit[1])
  const bricks = perTile(look.unit[0])
  const ch = SIZE / courses
  const bw = SIZE / bricks
  const joint = Math.max(1, look.joint * PX)
  fill(ctx, shade(look.base, look.joint_shade))
  fill(hctx, "#000000")
  fill(rctx, "#ffffff")
  for (let r = 0; r < courses; r += 1) {
    const offset = r % 2 === 0 ? 0 : bw / 2
    for (let c = -1; c <= bricks; c += 1) {
      const x = c * bw + offset + joint / 2
      const y = r * ch + joint / 2
      const w = bw - joint
      const h = ch - joint
      const unit = wrapped(c, bricks)
      box(ctx, shade(look.base, 1 + (noise(r, unit, 0) - 0.5) * 2 * look.variation), x, y, w, h)
      box(hctx, grey(0.85 + 0.15 * noise(r, unit, 1)), x, y, w, h)
      box(rctx, grey(spec.roughness ?? 0.85), x, y, w, h)
    }
  }
}

// Overlapping courses: `unit[1]` tall, tiles `unit[0]` wide, offset half a tile per course.
// Each course's lower edge stands proud with a shadow line under it, which is the relief
// a tiled roof actually has.
function tiles(ctx, hctx, rctx, look, spec) {
  const courses = perTileEven(look.unit[1])
  const across = perTile(look.unit[0])
  const ch = SIZE / courses
  const tw = SIZE / across
  const joint = Math.max(1, look.joint * PX)
  const lip = Math.max(2, ch * 0.12)
  fill(ctx, shade(look.base, look.joint_shade))
  fill(hctx, "#000000")
  fill(rctx, grey(spec.roughness ?? 0.8))
  for (let r = 0; r < courses; r += 1) {
    const offset = r % 2 === 0 ? 0 : tw / 2
    for (let c = -1; c <= across; c += 1) {
      const x = c * tw + offset + joint / 2
      const y = r * ch
      const w = tw - joint
      const value = 1 + (noise(r, wrapped(c, across), 2) - 0.5) * 2 * look.variation
      box(ctx, shade(look.base, value), x, y, w, ch - lip)
      box(ctx, shade(look.base, value * look.joint_shade), x, y + ch - lip, w, lip)
      // Height rises down the course so the lower edge is the proud one.
      if (hctx) {
        const gradient = hctx.createLinearGradient(0, y, 0, y + ch - lip)
        gradient.addColorStop(0, grey(0.55))
        gradient.addColorStop(1, grey(1.0))
        hctx.fillStyle = gradient
        hctx.fillRect(x, y, w, ch - lip)
      }
    }
  }
}

// Boards `unit[0]` wide running up the surface's v axis -- up a door, along a deck -- with
// a dark seam between and a little grain along them.
function planks(ctx, hctx, rctx, look, spec) {
  const boards = perTile(look.unit[0])
  const bw = SIZE / boards
  const seam = Math.max(1, look.joint * PX)
  fill(ctx, shade(look.base, look.joint_shade))
  fill(hctx, "#000000")
  fill(rctx, grey(spec.roughness ?? 0.85))
  for (let b = 0; b < boards; b += 1) {
    const x = b * bw + seam / 2
    const value = 1 + (noise(b, 0, 3) - 0.5) * 2 * look.variation
    box(ctx, shade(look.base, value), x, 0, bw - seam, SIZE)
    box(hctx, grey(0.8 + 0.2 * noise(b, 1, 3)), x, 0, bw - seam, SIZE)
    for (let g = 0; g < 6; g += 1) {
      const gx = x + noise(b, g, 4) * (bw - seam)
      box(ctx, shade(look.base, value * (1 - look.variation * 0.4)), gx, 0, 1, SIZE)
    }
  }
}

// Flat with a little low-frequency mottling.
function plaster(ctx, hctx, rctx, look, spec) {
  fill(ctx, look.base)
  fill(hctx, grey(0.5))
  fill(rctx, grey(spec.roughness ?? 0.85))
  for (let i = 0; i < 40; i += 1) {
    const x = noise(i, 0, 5) * SIZE
    const y = noise(i, 1, 5) * SIZE
    const r = (0.15 + 0.35 * noise(i, 2, 5)) * PX
    const value = 1 + (noise(i, 3, 5) - 0.5) * 2 * look.variation
    blot(ctx, shade(look.base, value), x, y, r, 0.35)
  }
}

// Speckle and faint blotches, no relief to speak of.
function concrete(ctx, hctx, rctx, look, spec) {
  fill(ctx, look.base)
  fill(hctx, grey(0.5))
  fill(rctx, grey(spec.roughness ?? 0.95))
  for (let i = 0; i < 30; i += 1) {
    blot(ctx, shade(look.base, 1 + (noise(i, 3, 6) - 0.5) * look.variation), noise(i, 0, 6) * SIZE, noise(i, 1, 6) * SIZE, (0.2 + 0.5 * noise(i, 2, 6)) * PX, 0.3)
  }
  for (let i = 0; i < 6000; i += 1) {
    const x = noise(i, 0, 7) * SIZE
    const y = noise(i, 1, 7) * SIZE
    box(ctx, shade(look.base, 1 + (noise(i, 2, 7) - 0.5) * 2 * look.variation), x, y, 1 + noise(i, 3, 7), 1 + noise(i, 4, 7))
    box(hctx, grey(0.5 + (noise(i, 2, 7) - 0.5) * 0.3), x, y, 1, 1)
  }
}

// A transparent pane inside an opaque frame. `unit[0]` is the frame's width in metres of
// a one-metre cell; this texture maps per cell, so the frame goes round each pane.
function glass(ctx, hctx, rctx, look, spec) {
  const frame = Math.max(2, look.unit[0] * SIZE)
  ctx.clearRect(0, 0, SIZE, SIZE)
  fill(ctx, shade(look.base, 0.55))
  ctx.clearRect(frame, frame, SIZE - 2 * frame, SIZE - 2 * frame)
  const value = parseInt(look.base.slice(1), 16)
  ctx.fillStyle = `rgba(${(value >> 16) & 255}, ${(value >> 8) & 255}, ${value & 255}, 0.35)`
  ctx.fillRect(frame, frame, SIZE - 2 * frame, SIZE - 2 * frame)
  fill(hctx, "#ffffff")
  box(hctx, grey(0.7), frame, frame, SIZE - 2 * frame, SIZE - 2 * frame)
  fill(rctx, grey(0.6))
  box(rctx, grey(spec.roughness ?? 0.08), frame, frame, SIZE - 2 * frame, SIZE - 2 * frame)
}

// Leaves: a dense speckle of small lobes, light against dark, with relief from the same.
function leaves(ctx, hctx, rctx, look, spec) {
  fill(ctx, shade(look.base, 0.7))
  fill(hctx, grey(0.4))
  fill(rctx, grey(spec.roughness ?? 0.9))
  for (let i = 0; i < 2400; i += 1) {
    const x = noise(i, 0, 8) * SIZE
    const y = noise(i, 1, 8) * SIZE
    const r = (0.02 + 0.05 * noise(i, 2, 8)) * PX
    const value = 1 + (noise(i, 3, 8) - 0.5) * 2 * look.variation
    blot(ctx, shade(look.base, value), x, y, r, 1)
    blot(hctx, grey(0.4 + 0.6 * noise(i, 3, 8)), x, y, r, 1)
  }
}

// A soft disc, drawn again across the tile's edge so the wrap is seamless -- but only
// across an edge it actually reaches. A copy exists to carry the part of a blot that hangs
// over the edge, so one lying wholly inside has nothing to carry and its eight copies are
// eight fills off the canvas. Concrete draws six thousand blots and leaves two thousand
// four hundred: at nine fills each that was most of what booting at `high` costs.
function blot(ctx, colour, x, y, r, alpha) {
  if (!ctx) return
  ctx.globalAlpha = alpha
  ctx.fillStyle = colour
  // The ellipse is r across and 0.7r high whatever its rotation, so r is the reach on
  // both axes and the test is the same one twice.
  const xs = [ 0 ]
  if (x < r) xs.push(SIZE)
  else if (x > SIZE - r) xs.push(-SIZE)
  const ys = [ 0 ]
  if (y < r) ys.push(SIZE)
  else if (y > SIZE - r) ys.push(-SIZE)

  for (const dx of xs) {
    for (const dy of ys) {
      ctx.beginPath()
      ctx.ellipse(x + dx, y + dy, r, r * 0.7, noise(x | 0, y | 0, 9) * Math.PI, 0, Math.PI * 2)
      ctx.fill()
    }
  }
  ctx.globalAlpha = 1
}

const PAINTERS = { brick, tiles, planks, plaster, concrete, glass, leaves }

// A tangent-space normal map from a height canvas by central differences, wrapping at
// the edges so the tile stays seamless. Canvas y grows downward and texture v upward, so
// the green channel takes the gradient with its sign as canvas reads it.
function normalFrom(heightCanvas) {
  const ctx = heightCanvas.getContext("2d")
  const src = ctx.getImageData(0, 0, SIZE, SIZE).data
  const out = canvas()
  const octx = out.getContext("2d")
  const image = octx.createImageData(SIZE, SIZE)
  const strength = 3.0
  const h = (x, y) => src[(((y + SIZE) % SIZE) * SIZE + ((x + SIZE) % SIZE)) * 4] / 255

  for (let y = 0; y < SIZE; y += 1) {
    for (let x = 0; x < SIZE; x += 1) {
      const dx = h(x + 1, y) - h(x - 1, y)
      const dy = h(x, y + 1) - h(x, y - 1)
      let nx = -dx * strength
      let ny = dy * strength
      let nz = 1
      const length = Math.hypot(nx, ny, nz)
      nx /= length
      ny /= length
      nz /= length
      const i = (y * SIZE + x) * 4
      image.data[i] = Math.round((nx * 0.5 + 0.5) * 255)
      image.data[i + 1] = Math.round((ny * 0.5 + 0.5) * 255)
      image.data[i + 2] = Math.round((nz * 0.5 + 0.5) * 255)
      image.data[i + 3] = 255
    }
  }
  octx.putImageData(image, 0, 0)
  return out
}
