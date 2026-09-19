import { render, screen, within } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it } from "vitest"
import { CATALOG_VIEWPORT_PRESETS, CatalogViewportSwitcher, viewportLink, viewportPresetFromSearch } from "./catalogViewport"

describe("viewportPresetFromSearch", () => {
  it("defaults to desktop when no viewport param is present", () => {
    expect(viewportPresetFromSearch("").id).toBe("desktop")
  })

  it("resolves a recognized viewport param", () => {
    expect(viewportPresetFromSearch("?viewport=wide").id).toBe("wide")
  })

  it("falls back to desktop for an unrecognized viewport param", () => {
    expect(viewportPresetFromSearch("?viewport=huge").id).toBe("desktop")
  })
})

describe("viewportLink", () => {
  it("sets the viewport param while preserving other params", () => {
    expect(viewportLink("/admin/things", "?tool_name=Bash", "phone")).toBe("/admin/things?tool_name=Bash&viewport=phone")
  })
})

describe("CatalogViewportSwitcher", () => {
  function renderSwitcher(search: string) {
    return render(
      <MemoryRouter>
        <CatalogViewportSwitcher
          ariaLabel="Preview viewport"
          labelFor={(preset) => `${preset.id} (${preset.width}px)`}
          pathname="/admin/things"
          search={search}
          selected={viewportPresetFromSearch(search).id}
        />
      </MemoryRouter>
    )
  }

  it("renders every preset as a tab and marks the selected one", () => {
    renderSwitcher("?viewport=phone")

    const switcher = screen.getByRole("tablist", { name: "Preview viewport" })
    expect(within(switcher).getAllByRole("tab")).toHaveLength(CATALOG_VIEWPORT_PRESETS.length)
    expect(within(switcher).getByRole("tab", { name: "phone (390px)", selected: true })).toBeInTheDocument()
    expect(within(switcher).getByRole("tab", { name: "desktop (1280px)", selected: false })).toBeInTheDocument()
  })

  it("links each preset to a URL carrying its own viewport param plus the existing search", () => {
    renderSwitcher("?tool_name=Bash")

    const wideTab = screen.getByRole("tab", { name: "wide (1600px)" })
    expect(wideTab).toHaveAttribute("href", expect.stringContaining("tool_name=Bash"))
    expect(wideTab).toHaveAttribute("href", expect.stringContaining("viewport=wide"))
  })
})
