import { renderHook } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { catalogAnchorId, useCatalogDeepLinkScroll } from "./catalogDeepLink"

describe("catalogAnchorId", () => {
  it("prefixes the key and sanitizes characters unsafe for a DOM id", () => {
    expect(catalogAnchorId("renderer", "erd_diagram")).toBe("renderer-erd_diagram")
    expect(catalogAnchorId("tool", "mcp__foo__bar baz!")).toBe("tool-mcp__foo__bar_baz_")
  })
})

describe("useCatalogDeepLinkScroll", () => {
  afterEach(() => {
    document.body.innerHTML = ""
    vi.restoreAllMocks()
  })

  it("scrolls to the element matching the given id once it exists", () => {
    const el = document.createElement("div")
    el.id = "renderer-erd_diagram"
    document.body.appendChild(el)
    const scrollIntoView = vi.fn()
    el.scrollIntoView = scrollIntoView

    renderHook(() => useCatalogDeepLinkScroll("renderer-erd_diagram", null))

    expect(scrollIntoView).toHaveBeenCalledWith({ block: "start" })
  })

  it("does nothing when elementId is null", () => {
    const scrollIntoView = vi.fn()
    Element.prototype.scrollIntoView = scrollIntoView

    renderHook(() => useCatalogDeepLinkScroll(null, null))

    expect(scrollIntoView).not.toHaveBeenCalled()
  })

  it("does nothing when no element matches the given id yet", () => {
    const scrollIntoView = vi.fn()
    Element.prototype.scrollIntoView = scrollIntoView

    renderHook(() => useCatalogDeepLinkScroll("renderer-does_not_exist", null))

    expect(scrollIntoView).not.toHaveBeenCalled()
  })

  it("only scrolls once per elementId even as the recompute trigger changes", () => {
    const el = document.createElement("div")
    el.id = "renderer-erd_diagram"
    document.body.appendChild(el)
    const scrollIntoView = vi.fn()
    el.scrollIntoView = scrollIntoView

    const { rerender } = renderHook(({ trigger }) => useCatalogDeepLinkScroll("renderer-erd_diagram", trigger), {
      initialProps: { trigger: 1 }
    })
    rerender({ trigger: 2 })
    rerender({ trigger: 3 })

    expect(scrollIntoView).toHaveBeenCalledTimes(1)
  })
})
