import { describe, expect, it } from "vitest"
import { mobileHeaderScrollDeltaForMessageStream } from "./messageStream"

describe("mobileHeaderScrollDeltaForMessageStream", () => {
  it("ignores tiny top and bottom boundary deltas but keeps intentional movement", () => {
    const stream = messageStream({ scrollHeight: 1200, clientHeight: 400, scrollTop: 0 })

    stream.scrollTop = 6
    expect(mobileHeaderScrollDeltaForMessageStream(stream, 0)).toBeNull()

    stream.scrollTop = 804
    expect(mobileHeaderScrollDeltaForMessageStream(stream, 800)).toBeNull()

    stream.scrollTop = 120
    expect(mobileHeaderScrollDeltaForMessageStream(stream, 0)).toBe(120)

    stream.scrollTop = 300
    expect(mobileHeaderScrollDeltaForMessageStream(stream, 420)).toBe(-120)

    stream.scrollTop = 0
    expect(mobileHeaderScrollDeltaForMessageStream(stream, 24)).toBe(-24)

    stream.scrollTop = 8
    expect(mobileHeaderScrollDeltaForMessageStream(stream, 40)).toBe(-32)
  })
})

function messageStream(metrics: { scrollHeight: number; clientHeight: number; scrollTop: number }) {
  const element = document.createElement("div")
  Object.defineProperty(element, "scrollHeight", { configurable: true, value: metrics.scrollHeight })
  Object.defineProperty(element, "clientHeight", { configurable: true, value: metrics.clientHeight })
  Object.defineProperty(element, "scrollTop", { configurable: true, writable: true, value: metrics.scrollTop })
  return element
}
