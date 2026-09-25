import { render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { AdminFiltersLayout } from "./AdminFiltersLayout"
import { Page } from "./ui/Page"

afterEach(() => {
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
})

function mockMobileViewport() {
  vi.stubGlobal(
    "matchMedia",
    vi.fn(() => ({
      matches: false,
      media: "(min-width: 1024px)",
      onchange: null,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      addListener: vi.fn(),
      removeListener: vi.fn(),
      dispatchEvent: vi.fn()
    }))
  )
}

describe("AdminFiltersLayout", () => {
  it("restores only the mobile filter disclosure margin inside a responsive Page.Root", () => {
    mockMobileViewport()

    render(
      <Page.Root gutter="responsive">
        <AdminFiltersLayout filterBar={<div>Filter controls</div>}>
          <section>Results table</section>
        </AdminFiltersLayout>
      </Page.Root>
    )

    const disclosure = screen.getByText("Folders and filters").closest("details")
    const results = screen.getByText("Results table")

    expect(disclosure?.className).toContain("mx-4 sm:mx-0")
    expect(results.className).not.toContain("mx-4 sm:mx-0")
  })

  it("places a short description above the FilterBar area", () => {
    render(
      <Page.Root gutter="responsive">
        <AdminFiltersLayout description={<p>Review active queue pressure before filtering.</p>} filterBar={<div>Filter controls</div>}>
          <section>Results table</section>
        </AdminFiltersLayout>
      </Page.Root>
    )

    const description = screen.getByText("Review active queue pressure before filtering.")
    const filterBar = screen.getByText("Filter controls")
    const results = screen.getByText("Results table")

    expect(description.compareDocumentPosition(filterBar) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    expect(filterBar.compareDocumentPosition(results) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    expect(description.parentElement?.className).toContain("mx-4 sm:mx-0")
  })

  it("keeps optional smart folders to the left of the table panel on desktop", () => {
    render(
      <Page.Root gutter="responsive">
        <AdminFiltersLayout filterBar={<div>Filter controls</div>} smartFolders={<aside>Saved queues</aside>}>
          <section>Results table</section>
        </AdminFiltersLayout>
      </Page.Root>
    )

    const grid = screen.getByText("Saved queues").parentElement
    expect(grid?.className).toContain("lg:grid-cols-[16rem_minmax(0,1fr)]")
    expect(screen.getByText("Saved queues").compareDocumentPosition(screen.getByText("Results table")) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
  })
})
