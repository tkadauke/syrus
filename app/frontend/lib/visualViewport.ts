export const KEYBOARD_VIEWPORT_HEIGHT_DIFFERENCE_PX = 100
export const UNZOOMED_VISUAL_VIEWPORT_SCALE_TOLERANCE = 0.01

export function keyboardVisualViewport() {
  if (typeof window === "undefined" || !window.visualViewport) return null

  const viewport = window.visualViewport
  const scale = viewport.scale
  const height = Math.round(viewport.height)
  const width = Math.round(viewport.width)
  const isUnzoomed = Number.isFinite(scale) && Math.abs(scale - 1) <= UNZOOMED_VISUAL_VIEWPORT_SCALE_TOLERANCE
  const isKeyboardHeight = height > 0 && window.innerHeight - height > KEYBOARD_VIEWPORT_HEIGHT_DIFFERENCE_PX

  if (!isUnzoomed || !isKeyboardHeight || width <= 0) return null

  return viewport
}
