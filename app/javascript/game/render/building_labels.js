import * as THREE from "three"

// Part of the debug overlay: a plate above every building near the car saying what it is,
// so a building can be talked about by name rather than pointed at. The plate carries the
// building's category, its object name, and the ids of the source records it was built
// from -- the BAG `Pand` ids of an imported row -- all of which arrive in the spec. The
// four hand-made worlds have no source ids and show the object's own id instead.
//
// Canvas sprites, like the hitbox labels on the car, but larger: these are read from
// tens of metres away, and they hang above rooflines, so depth testing is off and they
// are drawn last.
const WIDTH = 384
const HEIGHT = 144
// Metres across, on screen the plate is scaled by distance like anything else in the
// world, and at the far end of the range it is still a legible word or two.
const PLATE_WIDTH = 9
const PLATE_HEIGHT = PLATE_WIDTH * HEIGHT / WIDTH
// How far from the car a building still gets a plate, and how many plates at most --
// past a dozen they overlap into noise, and the nearest are the ones worth reading.
const RANGE = 75
const MAX_SHOWN = 12
// How far above the highest point of the building the plate floats.
const CLEARANCE = 3

const FILL = "rgba(14, 17, 22, 0.82)"
const BORDER = "#5a6470"
const CATEGORY_COLOUR = "#98a2ae"
const NAME_COLOUR = "#ffd79a"
const IDS_COLOUR = "#9fd8e6"

export class BuildingLabels {
  constructor(scene, buildings) {
    this.visible = true
    this.group = new THREE.Group()
    this.group.name = "building-labels"
    scene.add(this.group)
    this.entries = buildings.map((building) => this.entry(building))
  }

  entry(building) {
    const spec = building.spec
    const category = spec.category || "building"
    const ids = Array.isArray(spec.pands) && spec.pands.length > 0 ? spec.pands.map(String) : [ `#${building.id}` ]
    const anchor = anchorFor(building)

    const canvas = document.createElement("canvas")
    canvas.width = WIDTH
    canvas.height = HEIGHT
    draw(canvas.getContext("2d"), category, spec.name, ids)

    const texture = new THREE.CanvasTexture(canvas)
    const sprite = new THREE.Sprite(new THREE.SpriteMaterial({ map: texture, transparent: true, depthTest: false }))
    sprite.scale.set(PLATE_WIDTH, PLATE_HEIGHT, 1)
    sprite.renderOrder = 999
    sprite.position.copy(anchor)
    sprite.visible = false
    this.group.add(sprite)

    return { building, sprite, anchor, category, ids, distance: Infinity }
  }

  // Nearest first, within range, and only so many: the car's own position is the one
  // thing that changes from frame to frame.
  update(carPosition) {
    this.group.visible = this.visible
    if (!this.visible) return

    for (const entry of this.entries) {
      entry.distance = Math.hypot(entry.anchor.x - carPosition.x, entry.anchor.z - carPosition.z)
      entry.sprite.visible = false
    }
    this.entries
      .filter((entry) => entry.distance <= RANGE)
      .sort((a, b) => a.distance - b.distance)
      .slice(0, MAX_SHOWN)
      .forEach((entry) => { entry.sprite.visible = true })
  }

  // For tests and for talking about what is on screen: every building's plate, and
  // whether it is showing right now.
  readout() {
    return this.entries.map((entry) => ({
      id: entry.building.id,
      name: entry.building.name,
      category: entry.category,
      ids: entry.ids,
      shown: this.visible && entry.sprite.visible
    }))
  }

  dispose() {
    for (const entry of this.entries) {
      entry.sprite.material.map.dispose()
      entry.sprite.material.dispose()
    }
    this.group.removeFromParent()
  }
}

// The top centre of the building: the box around every surface's corners, wreckage
// excluded, because the rubble grid skirts the footprint and would pull the centre off
// an L-shaped building and the roofline down to the ground.
function anchorFor(building) {
  const box = new THREE.Box3()
  const point = new THREE.Vector3()
  const origin = new THREE.Vector3()
  const along = new THREE.Vector3()
  const up = new THREE.Vector3()

  for (const surface of building.spec.surfaces) {
    if (surface.kind === "rubble") continue

    origin.fromArray(surface.o).add(building.origin)
    along.fromArray(surface.u).multiplyScalar(surface.w)
    up.fromArray(surface.v).multiplyScalar(surface.h)
    box.expandByPoint(point.copy(origin))
    box.expandByPoint(point.copy(origin).add(along))
    box.expandByPoint(point.copy(origin).add(up))
    box.expandByPoint(point.copy(origin).add(along).add(up))
  }
  if (box.isEmpty()) return building.origin.clone()

  const centre = box.getCenter(new THREE.Vector3())
  return new THREE.Vector3(centre.x, box.max.y + CLEARANCE, centre.z)
}

function draw(ctx, category, name, ids) {
  ctx.clearRect(0, 0, WIDTH, HEIGHT)
  ctx.fillStyle = FILL
  ctx.fillRect(0, 0, WIDTH, HEIGHT)
  ctx.strokeStyle = BORDER
  ctx.lineWidth = 4
  ctx.strokeRect(2, 2, WIDTH - 4, HEIGHT - 4)

  ctx.textAlign = "center"
  ctx.fillStyle = CATEGORY_COLOUR
  ctx.font = "600 28px ui-sans-serif, system-ui, sans-serif"
  ctx.fillText(String(category).toUpperCase(), WIDTH / 2, 38)

  ctx.fillStyle = NAME_COLOUR
  ctx.font = "700 46px ui-sans-serif, system-ui, sans-serif"
  ctx.fillText(fit(ctx, String(name), WIDTH - 24), WIDTH / 2, 90)

  ctx.fillStyle = IDS_COLOUR
  ctx.font = "500 24px ui-monospace, Menlo, monospace"
  // Every id when they fit, otherwise the first and last and how many there are.
  let line = ids.join("  ")
  if (ctx.measureText(line).width > WIDTH - 24 && ids.length > 2) {
    line = `${ids[0]} … ${ids[ids.length - 1]}  (${ids.length})`
  }
  ctx.fillText(fit(ctx, line, WIDTH - 24), WIDTH / 2, 128)
}

// Trims a string with an ellipsis until it fits the width in the current font.
function fit(ctx, text, width) {
  let out = text
  while (out.length > 3 && ctx.measureText(out).width > width) out = `${out.slice(0, -2)}…`
  return out
}
