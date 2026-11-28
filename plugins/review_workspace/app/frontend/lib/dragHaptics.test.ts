import { describe, expect, it } from "vitest"
import { DragHapticQuantizer } from "./dragHaptics"

function make(overrides = {}) {
  let time = 0
  const q = new DragHapticQuantizer({ increment: 24, max: 72, minIntervalMs: 35, now: () => time, ...overrides })
  return { q, advance: (ms = 100) => (time += ms) }
}

describe("DragHapticQuantizer", () => {
  it("ticks once per increment crossed and not between", () => {
    const { q, advance } = make()
    const ticks = [10, 23, 25, 40, 49, 60, 73].map((d) => (advance(), q.update(d)))
    expect(ticks).toEqual([false, false, true, false, true, false, true])
  })

  it("ignores duplicate move events at the same distance", () => {
    const { q, advance } = make()
    expect(q.update(30)).toBe(true)
    advance()
    expect(q.update(30)).toBe(false)
  })

  it("ticks when reversing back across an increment", () => {
    const { q, advance } = make()
    q.update(50)
    advance()
    expect(q.update(46)).toBe(false)
    advance()
    expect(q.update(10)).toBe(true)
    advance()
    expect(q.update(0)).toBe(false)
    advance()
    expect(q.update(30)).toBe(true)
  })

  it("does not chatter when jittering around a boundary", () => {
    const { q, advance } = make()
    q.update(25)
    const ticks = [23, 25, 22, 26, 23.5, 25].map((d) => (advance(), q.update(d)))
    expect(ticks.every((t) => !t)).toBe(true)
  })

  it("clicks only once when one event jumps several increments", () => {
    const { q } = make()
    expect(q.update(70)).toBe(true)
  })

  it("never ticks past the maximum or for non-finite/negative distances", () => {
    const { q, advance } = make()
    q.update(72)
    advance()
    expect(q.update(500)).toBe(false)
    expect(q.update(Number.NaN)).toBe(false)
    expect(q.update(-20)).toBe(true)
    advance()
    expect(q.update(-40)).toBe(false)
  })

  it("throttles ticks that arrive faster than the minimum interval", () => {
    const { q, advance } = make()
    expect(q.update(25)).toBe(true)
    advance(5)
    expect(q.update(50)).toBe(false)
    advance(5)
    expect(q.update(10)).toBe(false)
  })
})
