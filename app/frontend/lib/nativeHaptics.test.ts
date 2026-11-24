import { afterEach, describe, expect, it, vi } from "vitest"
import { DragHapticQuantizer, nativeHapticsAvailable, sendNativeHaptic } from "./nativeHaptics"

function installHandler(postMessage = vi.fn()) {
  Object.defineProperty(window, "webkit", { configurable: true, value: { messageHandlers: { syrusHaptics: { postMessage } } } })
  return postMessage
}

afterEach(() => {
  Reflect.deleteProperty(window, "webkit")
  vi.unstubAllGlobals()
})

describe("sendNativeHaptic", () => {
  it("is a no-op in ordinary browsers", () => {
    expect(nativeHapticsAvailable()).toBe(false)
    expect(sendNativeHaptic("selection")).toBe(false)
    expect(sendNativeHaptic("commit")).toBe(false)
  })

  it("posts versioned messages to the iOS shell", () => {
    const post = installHandler()
    expect(sendNativeHaptic("selection")).toBe(true)
    expect(sendNativeHaptic("commit")).toBe(true)
    expect(post.mock.calls).toEqual([[{ v: 1, type: "selection" }], [{ v: 1, type: "commit" }]])
  })

  it("suppresses ticks but not the commit under reduced motion", () => {
    const post = installHandler()
    vi.stubGlobal("matchMedia", () => ({ matches: true }))
    expect(sendNativeHaptic("selection")).toBe(false)
    expect(sendNativeHaptic("commit")).toBe(true)
    expect(post).toHaveBeenCalledTimes(1)
  })

  it("swallows bridge errors", () => {
    installHandler(
      vi.fn(() => {
        throw new Error("boom")
      })
    )
    expect(sendNativeHaptic("commit")).toBe(false)
  })
})

describe("DragHapticQuantizer", () => {
  function make() {
    let time = 0
    const quantizer = new DragHapticQuantizer(20, 40, () => time)
    return { quantizer, advance: (ms: number) => (time += ms) }
  }

  it("ticks once per step crossed", () => {
    const { quantizer, advance } = make()
    const ticks: boolean[] = []
    for (const x of [5, 19, 20, 30, 39, 40, 61]) {
      advance(50)
      ticks.push(quantizer.update(x))
    }
    expect(ticks).toEqual([false, false, true, false, false, true, true])
  })

  it("ignores duplicate offsets", () => {
    const { quantizer, advance } = make()
    advance(50)
    expect(quantizer.update(25)).toBe(true)
    advance(50)
    expect(quantizer.update(25)).toBe(false)
  })

  it("requires a full step back after reversing and does not buzz at a boundary", () => {
    const { quantizer, advance } = make()
    advance(50)
    expect(quantizer.update(20)).toBe(true)
    for (const x of [21, 19, 21, 19, 22]) {
      advance(50)
      expect(quantizer.update(x)).toBe(false)
    }
    advance(50)
    expect(quantizer.update(-1)).toBe(true)
    advance(50)
    expect(quantizer.update(-21)).toBe(true)
  })

  it("collapses large jumps into one tick and throttles bursts", () => {
    const { quantizer, advance } = make()
    advance(50)
    expect(quantizer.update(100)).toBe(true)
    advance(10)
    expect(quantizer.update(120)).toBe(false)
    advance(50)
    expect(quantizer.update(140)).toBe(true)
  })

  it("reset re-anchors", () => {
    const { quantizer, advance } = make()
    quantizer.reset(100)
    advance(50)
    expect(quantizer.update(110)).toBe(false)
    expect(quantizer.update(120)).toBe(true)
  })
})
