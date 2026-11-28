import { afterEach, describe, expect, it, vi } from "vitest"
import { haptics, HAPTICS_PREFERENCE_KEY, iosHapticsAvailable } from "./iosHaptics"

const post = vi.fn()

function installShell(userAgent = "Mozilla/5.0 SyrusiOS/1.0") {
  vi.spyOn(navigator, "userAgent", "get").mockReturnValue(userAgent)
  ;(window as unknown as { webkit?: unknown }).webkit = { messageHandlers: { syrusHaptics: { postMessage: post } } }
}

afterEach(() => {
  delete (window as unknown as { webkit?: unknown }).webkit
  delete (window as unknown as { matchMedia?: unknown }).matchMedia
  window.localStorage.clear()
  post.mockReset()
  vi.restoreAllMocks()
})

describe("iosHaptics", () => {
  it("is a silent no-op in an ordinary browser", () => {
    expect(iosHapticsAvailable()).toBe(false)
    expect(haptics.selection()).toBe(false)
    expect(haptics.impact("medium")).toBe(false)
  })

  it("ignores a webkit handler when the page is not hosted by the iOS shell", () => {
    installShell("Mozilla/5.0 Safari/605")
    expect(iosHapticsAvailable()).toBe(false)
    expect(haptics.selection()).toBe(false)
    expect(post).not.toHaveBeenCalled()
  })

  it("posts the exact validated payloads", () => {
    installShell()
    expect(haptics.selection()).toBe(true)
    expect(haptics.impact("heavy")).toBe(true)
    expect(haptics.impact()).toBe(true)
    expect(post.mock.calls).toEqual([[{ v: 1, kind: "selection" }], [{ v: 1, kind: "impact", style: "heavy" }], [{ v: 1, kind: "impact", style: "medium" }]])
  })

  it("respects reduced motion and the local opt-out", () => {
    installShell()
    window.localStorage.setItem(HAPTICS_PREFERENCE_KEY, "off")
    expect(haptics.selection()).toBe(false)
    window.localStorage.clear()
    window.matchMedia = vi.fn().mockReturnValue({ matches: true }) as unknown as typeof window.matchMedia
    expect(haptics.impact("medium")).toBe(false)
    expect(post).not.toHaveBeenCalled()
  })

  it("swallows bridge failures", () => {
    installShell()
    post.mockImplementation(() => {
      throw new Error("gone")
    })
    expect(haptics.selection()).toBe(false)
  })
})
