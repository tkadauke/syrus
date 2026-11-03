/**
 * Registry of open nested layers (modals, sheets) that can be dismissed by the back gesture.
 * The mobile Activity shell asks this registry to close the topmost layer before it handles
 * back itself, so back ownership is explicit rather than inferred from the DOM.
 */
const layers: Array<() => void> = []

export function registerDismissLayer(dismiss: () => void) {
  layers.push(dismiss)
  return () => {
    const index = layers.lastIndexOf(dismiss)
    if (index >= 0) layers.splice(index, 1)
  }
}

export function hasDismissLayers() {
  return layers.length > 0
}

/** Closes the topmost registered layer. Returns false when there was nothing to close. */
export function dismissTopLayer() {
  const top = layers[layers.length - 1]
  if (!top) return false
  top()
  return true
}
