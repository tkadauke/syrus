import { renderHook } from "@testing-library/react"
import { describe, expect, it, beforeEach } from "vitest"
import { usePageTitle } from "./usePageTitle"

describe("usePageTitle", () => {
  beforeEach(() => {
    document.title = "Initial Title"
  })

  it("sets document.title with the app suffix when a title is given", () => {
    renderHook(() => usePageTitle("Dashboard"))
    expect(document.title).toBe("Dashboard | Syrus")
  })

  it("sets Syrus alone when title is null", () => {
    renderHook(() => usePageTitle(null))
    expect(document.title).toBe("Syrus")
  })

  it("sets Syrus alone when title is undefined", () => {
    renderHook(() => usePageTitle(undefined))
    expect(document.title).toBe("Syrus")
  })

  it("restores the previous title on unmount", () => {
    document.title = "Outer Page | Syrus"
    const { unmount } = renderHook(() => usePageTitle("Inner Page"))
    expect(document.title).toBe("Inner Page | Syrus")
    unmount()
    expect(document.title).toBe("Outer Page | Syrus")
  })

  it("updates document.title when the title changes", () => {
    const { rerender } = renderHook(({ title }: { title: string }) => usePageTitle(title), {
      initialProps: { title: "First" }
    })
    expect(document.title).toBe("First | Syrus")
    rerender({ title: "Second" })
    expect(document.title).toBe("Second | Syrus")
  })
})
