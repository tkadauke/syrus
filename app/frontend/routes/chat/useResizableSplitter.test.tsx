import { act, renderHook } from "@testing-library/react"
import type { MouseEvent as ReactMouseEvent } from "react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { useResizableSplitter } from "./useResizableSplitter"

function resizeStartEvent(clientX: number): ReactMouseEvent<HTMLDivElement> {
  return { clientX, preventDefault: vi.fn() } as unknown as ReactMouseEvent<HTMLDivElement>
}

describe("useResizableSplitter", () => {
  afterEach(() => {
    window.localStorage.clear()
    vi.restoreAllMocks()
    vi.useRealTimers()
  })

  it("removes active window resize listeners when unmounted mid-drag", () => {
    const clampWidth = vi.fn((width: number) => width)
    const setItem = vi.spyOn(Storage.prototype, "setItem")
    const addEventListener = vi.spyOn(window, "addEventListener")
    const removeEventListener = vi.spyOn(window, "removeEventListener")
    const { result, unmount } = renderHook(() => useResizableSplitter({
      widthKey: "splitter-width",
      collapsedKey: "splitter-collapsed",
      initialWidth: 160,
      initialCollapsed: false,
      defaultWidth: 160,
      snapClosedWidth: 40,
      reopenWidth: 72,
      clampWidth
    }))

    act(() => {
      result.current.beginResize(resizeStartEvent(100))
    })

    const mouseMoveListener = addEventListener.mock.calls.find(([eventName]) => eventName === "mousemove")?.[1]
    const mouseUpListener = addEventListener.mock.calls.find(([eventName]) => eventName === "mouseup")?.[1]
    expect(mouseMoveListener).toBeTypeOf("function")
    expect(mouseUpListener).toBeTypeOf("function")

    unmount()

    expect(removeEventListener).toHaveBeenCalledWith("mousemove", mouseMoveListener)
    expect(removeEventListener).toHaveBeenCalledWith("mouseup", mouseUpListener)

    const preferenceWritesAfterUnmount = setItem.mock.calls.length
    act(() => {
      window.dispatchEvent(new MouseEvent("mousemove", { clientX: 220 }))
    })

    expect(clampWidth).not.toHaveBeenCalled()
    expect(setItem).toHaveBeenCalledTimes(preferenceWritesAfterUnmount)
  })

  it("clears the delayed dragged reset timer when unmounted after mouseup", () => {
    vi.useFakeTimers()
    const clearTimeout = vi.spyOn(window, "clearTimeout")
    const { result, unmount } = renderHook(() => useResizableSplitter({
      widthKey: "splitter-width",
      collapsedKey: "splitter-collapsed",
      initialWidth: 160,
      initialCollapsed: false,
      defaultWidth: 160,
      snapClosedWidth: 40,
      reopenWidth: 72,
      clampWidth: (width) => width
    }))

    act(() => {
      result.current.beginResize(resizeStartEvent(100))
    })
    act(() => {
      window.dispatchEvent(new MouseEvent("mouseup"))
    })

    unmount()

    expect(clearTimeout).toHaveBeenCalled()
  })
})
