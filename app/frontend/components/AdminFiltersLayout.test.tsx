import { render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { AdminFiltersLayout } from "./AdminFiltersLayout"
import { Page } from "./ui/Page"

afterEach(() => {
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
})

function mockMobileViewport() {
  vi.stubGlobal("matchMedia", vi.fn(() => ({
    matches: false,
    media: "(min-width: 1024px)",
    onchange: null,
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
    addListener: vi.fn(),
    removeListener: vi.fn(),
    dispatchEvent: vi.fn()
  })))
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
})
