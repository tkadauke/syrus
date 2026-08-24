import { act, renderHook } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { useCopyToClipboard } from "./useCopyToClipboard"

describe("useCopyToClipboard", () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })

  afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
  })

  it("flips copied to true after a successful write, then resets after the delay", async () => {
    const writeText = vi.fn().mockResolvedValue(undefined)
    Object.assign(navigator, { clipboard: { writeText } })

    const { result } = renderHook(() => useCopyToClipboard(1500))
    expect(result.current.copied).toBe(false)

    await act(async () => {
      result.current.copy("hello")
      await Promise.resolve()
    })

    expect(writeText).toHaveBeenCalledWith("hello")
    expect(result.current.copied).toBe(true)

    act(() => {
      vi.advanceTimersByTime(1500)
    })
    expect(result.current.copied).toBe(false)
  })

  it("stays false when the clipboard write is rejected", async () => {
    const writeText = vi.fn().mockRejectedValue(new Error("denied"))
    Object.assign(navigator, { clipboard: { writeText } })

    const { result } = renderHook(() => useCopyToClipboard())

    await act(async () => {
      result.current.copy("hello")
      await Promise.resolve()
    })

    expect(result.current.copied).toBe(false)
  })

  it("does nothing when the Clipboard API is unavailable", () => {
    Object.assign(navigator, { clipboard: undefined })

    const { result } = renderHook(() => useCopyToClipboard())

    act(() => {
      result.current.copy("hello")
    })

    expect(result.current.copied).toBe(false)
  })
})
