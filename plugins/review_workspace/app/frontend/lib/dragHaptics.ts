// Turns a continuous drag distance into discrete haptic "clicks".
//
// A tick fires when the distance crosses a multiple of `increment`, in either
// direction. Hysteresis stops finger jitter on a boundary from clicking
// repeatedly, a minimum interval caps the rate, and repeated identical
// distances (duplicate move events) never tick. The range is clamped to
// [0, max] so nothing ticks past the commit threshold.

export const DRAG_HAPTIC_INCREMENT = 24
const DEFAULT_HYSTERESIS = 4
const DEFAULT_MIN_INTERVAL_MS = 35

export type DragHapticOptions = {
  increment?: number
  max?: number
  hysteresis?: number
  minIntervalMs?: number
  now?: () => number
}

export class DragHapticQuantizer {
  private step = 0
  private lastTickAt = Number.NEGATIVE_INFINITY
  private readonly increment: number
  private readonly max: number
  private readonly hysteresis: number
  private readonly minIntervalMs: number
  private readonly now: () => number

  constructor({ increment = DRAG_HAPTIC_INCREMENT, max = Number.POSITIVE_INFINITY, hysteresis, minIntervalMs = DEFAULT_MIN_INTERVAL_MS, now }: DragHapticOptions = {}) {
    this.increment = increment > 0 ? increment : DRAG_HAPTIC_INCREMENT
    this.max = max
    this.hysteresis = Math.min(hysteresis ?? DEFAULT_HYSTERESIS, this.increment / 2)
    this.minIntervalMs = minIntervalMs
    this.now = now ?? (() => (typeof performance !== "undefined" ? performance.now() : Date.now()))
  }

  // Returns true when this distance crossed an increment and a tick is due.
  update(distance: number): boolean {
    if (!Number.isFinite(distance)) return false
    const clamped = Math.min(Math.max(0, distance), this.max)
    const before = this.step
    while (clamped >= (this.step + 1) * this.increment) this.step += 1
    while (this.step > 0 && clamped < this.step * this.increment - this.hysteresis) this.step -= 1
    if (this.step === before) return false
    // Jumping several increments in one event still produces a single click.
    const time = this.now()
    if (time - this.lastTickAt < this.minIntervalMs) return false
    this.lastTickAt = time
    return true
  }
}
