/**
 * Bridge to the native iOS shell's haptics. Only the Syrus iOS app registers
 * the `syrusHaptics` script message handler; everywhere else (ordinary
 * browsers, desktop shell) every call here is a silent no-op.
 */

export type NativeHaptic = "selection" | "commit"

const HANDLER_NAME = "syrusHaptics"
const PROTOCOL_VERSION = 1

type HapticsHandler = { postMessage: (message: unknown) => void }

function handler(): HapticsHandler | undefined {
  if (typeof window === "undefined") return undefined
  const candidate = (window as unknown as { webkit?: { messageHandlers?: Record<string, HapticsHandler | undefined> } }).webkit?.messageHandlers?.[
    HANDLER_NAME
  ]
  return candidate && typeof candidate.postMessage === "function" ? candidate : undefined
}

export function nativeHapticsAvailable() {
  return handler() !== undefined
}

function prefersReducedMotion() {
  return typeof window !== "undefined" && Boolean(window.matchMedia?.("(prefers-reduced-motion: reduce)").matches)
}

/**
 * Requests native feedback. Incremental `selection` ticks are suppressed when
 * the user prefers reduced motion; the single `commit` impact is still played.
 * (The OS additionally honours the system haptics setting.) Returns whether a
 * request was sent.
 */
export function sendNativeHaptic(kind: NativeHaptic): boolean {
  const target = handler()
  if (!target) return false
  if (kind === "selection" && prefersReducedMotion()) return false
  try {
    target.postMessage({ v: PROTOCOL_VERSION, type: kind })
    return true
  } catch {
    // handled-error-expected: haptics are best-effort feedback; a failed bridge call must never affect the gesture
    return false
  }
}

export const DRAG_HAPTIC_STEP_PX = 24
export const DRAG_HAPTIC_MIN_INTERVAL_MS = 40

/**
 * Turns a stream of drag offsets into discrete tick decisions.
 *
 * An anchor trails the finger: each time the offset moves a full `stepPx`
 * from the anchor the anchor advances by whole steps and one tick is
 * reported. Reversing therefore needs a full step of travel back before the
 * next tick (hysteresis), so jitter around a boundary never buzzes. Repeated
 * identical offsets produce nothing, a large jump produces a single tick, and
 * ticks closer together than `minIntervalMs` are dropped.
 */
export class DragHapticQuantizer {
  private anchor = 0
  private lastTickAt = Number.NEGATIVE_INFINITY

  constructor(
    private readonly stepPx = DRAG_HAPTIC_STEP_PX,
    private readonly minIntervalMs = DRAG_HAPTIC_MIN_INTERVAL_MS,
    private readonly now: () => number = () => performance.now()
  ) {}

  reset(offset = 0) {
    this.anchor = offset
  }

  /** Returns true when a tick should be played for this offset. */
  update(offset: number): boolean {
    const delta = offset - this.anchor
    const steps = Math.trunc(Math.abs(delta) / this.stepPx)
    if (steps === 0) return false
    this.anchor += Math.sign(delta) * steps * this.stepPx
    const time = this.now()
    if (time - this.lastTickAt < this.minIntervalMs) return false
    this.lastTickAt = time
    return true
  }
}
