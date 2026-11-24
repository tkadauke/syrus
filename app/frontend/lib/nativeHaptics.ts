// Haptics bridge for the Syrus iOS shell (a WKWebView wrapper).
//
// The shell registers a single script message handler named `syrusHaptics`.
// Ordinary browsers (and older shells) have no such handler, so every export
// here degrades to a no-op. The wire format is deliberately tiny and is
// validated again on the Swift side:
//
//   { v: 1, kind: "selection" }
//   { v: 1, kind: "impact", style: "light" | "medium" | "heavy" | "soft" | "rigid" }

export type ImpactStyle = "light" | "medium" | "heavy" | "soft" | "rigid"
export type HapticMessage = { v: 1; kind: "selection" } | { v: 1; kind: "impact"; style: ImpactStyle }

type HapticsHandler = { postMessage: (message: HapticMessage) => void }

declare global {
  interface Window {
    webkit?: { messageHandlers?: { syrusHaptics?: HapticsHandler } }
  }
}

function handler(): HapticsHandler | null {
  if (typeof window === "undefined") return null
  const candidate = window.webkit?.messageHandlers?.syrusHaptics
  return candidate && typeof candidate.postMessage === "function" ? candidate : null
}

export function nativeHapticsAvailable(): boolean {
  return handler() !== null
}

function send(message: HapticMessage): boolean {
  const target = handler()
  if (!target) return false
  try {
    target.postMessage(message)
    return true
  } catch {
    // handled-error-expected: a shell that rejects the message must never break the web UI; haptics are best-effort.
    return false
  }
}

export function selectionHaptic(): boolean {
  return send({ v: 1, kind: "selection" })
}

export function impactHaptic(style: ImpactStyle = "medium"): boolean {
  return send({ v: 1, kind: "impact", style })
}

export const DRAG_HAPTIC_INCREMENT_PX = 24
export const DRAG_HAPTIC_MIN_INTERVAL_MS = 45

export type DragHapticsOptions = {
  // Horizontal distance between ticks, in CSS pixels.
  increment?: number
  // Minimum time between ticks; faster crossings are coalesced.
  minIntervalMs?: number
  now?: () => number
  emit?: () => void
}

export type DragHaptics = {
  // Feed the card's horizontal offset from where the drag began. Returns true
  // when a tick was emitted.
  move: (offsetX: number) => boolean
  // Forget the current drag (cancel, scroll takeover, programmatic reset).
  reset: () => void
}

// Quantizes a drag offset into increments of `increment` pixels and emits one
// selection tick whenever the quantized step changes, in either direction.
// The step is always tracked, even when a tick is throttled, so a fast flick
// cannot queue up a burst and reversing direction ticks exactly once per
// boundary crossed. Repeated moves at the same offset are ignored.
export function createDragHaptics(options: DragHapticsOptions = {}): DragHaptics {
  const increment = options.increment && options.increment > 0 ? options.increment : DRAG_HAPTIC_INCREMENT_PX
  const minInterval = options.minIntervalMs ?? DRAG_HAPTIC_MIN_INTERVAL_MS
  const now = options.now ?? (() => performance.now())
  const emit = options.emit ?? (() => void selectionHaptic())
  let step = 0
  let lastEmit = Number.NEGATIVE_INFINITY

  return {
    move(offsetX) {
      if (!Number.isFinite(offsetX)) return false
      const next = Math.trunc(offsetX / increment)
      if (next === step) return false
      step = next
      const time = now()
      if (time - lastEmit < minInterval) return false
      lastEmit = time
      emit()
      return true
    },
    reset() {
      step = 0
      lastEmit = Number.NEGATIVE_INFINITY
    }
  }
}
