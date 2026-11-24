import { afterEach, describe, expect, it, vi } from "vitest"
import { createDragHaptics, impactHaptic, nativeHapticsAvailable, selectionHaptic } from "./nativeHaptics"

function installHandler(postMessage: (m: unknown) => void) {
  window.webkit = { messageHandlers: { syrusHaptics: { postMessage } } }
}

afterEach(() => {
  delete window.webkit
})

describe("native haptics adapter", () => {
  it("is a no-op in ordinary browsers", () => {
    expect(nativeHapticsAvailable()).toBe(false)
    expect(selectionHaptic()).toBe(false)
    expect(impactHaptic()).toBe(false)
  })

  it("posts versioned, minimal messages to the shell handler", () => {
    const post = vi.fn()
    installHandler(post)
    expect(nativeHapticsAvailable()).toBe(true)
    expect(selectionHaptic()).toBe(true)
    expect(impactHaptic("rigid")).toBe(true)
    expect(post.mock.calls).toEqual([[{ v: 1, kind: "selection" }], [{ v: 1, kind: "impact", style: "rigid" }]])
  })

  it("swallows handler failures", () => {
    installHandler(() => {
      throw new Error("boom")
    })
    expect(selectionHaptic()).toBe(false)
  })
})

describe("createDragHaptics", () => {
  function setup(minIntervalMs = 0) {
    let time = 1000
    const emit = vi.fn()
    const haptics = createDragHaptics({ increment: 20, minIntervalMs, now: () => time, emit })
    return { haptics, emit, advance: (ms: number) => (time += ms) }
  }

  it("ticks once per increment crossed and ignores sub-increment movement", () => {
    const { haptics, emit } = setup()
    expect(haptics.move(10)).toBe(false)
    expect(haptics.move(20)).toBe(true)
    expect(haptics.move(39)).toBe(false)
    expect(haptics.move(40)).toBe(true)
    expect(emit).toHaveBeenCalledTimes(2)
  })

  it("ticks in both directions and on reversal across a boundary", () => {
    const { haptics, emit } = setup()
    haptics.move(45)
    emit.mockClear()
    expect(haptics.move(41)).toBe(false)
    expect(haptics.move(39)).toBe(true)
    expect(haptics.move(41)).toBe(true)
    expect(haptics.move(-25)).toBe(true)
    expect(emit).toHaveBeenCalledTimes(3)
  })

  it("ignores duplicate offsets", () => {
    const { haptics, emit } = setup()
    haptics.move(25)
    haptics.move(25)
    haptics.move(25)
    expect(emit).toHaveBeenCalledTimes(1)
  })

  it("throttles bursts without queueing them and keeps tracking the step", () => {
    const { haptics, emit, advance } = setup(50)
    expect(haptics.move(20)).toBe(true)
    advance(10)
    expect(haptics.move(100)).toBe(false)
    advance(10)
    expect(haptics.move(100)).toBe(false)
    advance(60)
    expect(haptics.move(100)).toBe(false) // step unchanged, nothing queued
    expect(haptics.move(120)).toBe(true)
    expect(emit).toHaveBeenCalledTimes(2)
  })

  it("rejects non-finite offsets and resets between drags", () => {
    const { haptics, emit } = setup()
    expect(haptics.move(Number.NaN)).toBe(false)
    haptics.move(30)
    haptics.reset()
    expect(haptics.move(30)).toBe(true)
    expect(emit).toHaveBeenCalledTimes(2)
  })
})
