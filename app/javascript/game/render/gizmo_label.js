import * as THREE from "three"

// Canvas-textured sprites used by the debug overlay. Shared so the hitboxes bolted to the
// car and the ones that follow live rockets look and behave identically.
export const ARMED_COLOUR = "#ff8a1f"
export const IDLE_COLOUR = "#5a6470"

const WIDTH = 256
const HEIGHT = 128

export function createLabel({ scale = [ 1.7, 0.85 ] } = {}) {
  const canvas = document.createElement("canvas")
  canvas.width = WIDTH
  canvas.height = HEIGHT

  const texture = new THREE.CanvasTexture(canvas)
  const sprite = new THREE.Sprite(
    new THREE.SpriteMaterial({ map: texture, transparent: true, depthTest: false })
  )
  sprite.scale.set(scale[0], scale[1], 1)
  // Draw last so labels are never buried inside the bodywork they describe.
  sprite.renderOrder = 999

  return { canvas, texture, sprite, context: canvas.getContext("2d"), last: null }
}

export const HIT_COLOUR = "#ff4d3d"

export function drawLabel(label, { title, value, footer, armed, highlight = false }) {
  const key = `${title}|${value}|${footer}|${armed}|${highlight}`
  if (label.last === key) return false
  label.last = key

  const ctx = label.context
  ctx.clearRect(0, 0, WIDTH, HEIGHT)

  // A hit highlights the whole plate -- background, border and title -- without changing
  // the number it is showing. The damage dealt floats separately.
  ctx.fillStyle = highlight ? "rgba(70, 18, 14, 0.88)" : "rgba(14, 17, 22, 0.78)"
  ctx.fillRect(0, 0, WIDTH, HEIGHT)
  ctx.strokeStyle = highlight ? HIT_COLOUR : armed ? ARMED_COLOUR : IDLE_COLOUR
  ctx.lineWidth = highlight ? 7 : 4
  ctx.strokeRect(2, 2, WIDTH - 4, HEIGHT - 4)

  ctx.textAlign = "center"
  ctx.fillStyle = highlight ? "#ffb4ab" : armed ? "#ffd79a" : "#98a2ae"
  ctx.font = "600 26px ui-sans-serif, system-ui, sans-serif"
  ctx.fillText(title, WIDTH / 2, 34)

  ctx.fillStyle = armed ? ARMED_COLOUR : IDLE_COLOUR
  ctx.font = "700 52px ui-sans-serif, system-ui, sans-serif"
  ctx.fillText(String(value), WIDTH / 2, 86)

  ctx.fillStyle = "#98a2ae"
  ctx.font = "500 22px ui-sans-serif, system-ui, sans-serif"
  ctx.fillText(footer, WIDTH / 2, 114)

  label.texture.needsUpdate = true
  return true
}

export function wireBox(size, colour = IDLE_COLOUR) {
  return new THREE.LineSegments(
    new THREE.EdgesGeometry(new THREE.BoxGeometry(size[0], size[1], size[2])),
    new THREE.LineBasicMaterial({ color: colour, transparent: true, opacity: 0.9 })
  )
}

export function disposeLabel(label) {
  label.texture.dispose()
  label.sprite.material.dispose()
}
