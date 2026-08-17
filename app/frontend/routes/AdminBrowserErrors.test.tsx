import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "../testSupport"
import { AdminBrowserErrors } from "./AdminBrowserErrors"

function renderRoute() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/admin/browser_errors"]}>
        <Routes>
          <Route element={<AdminBrowserErrors />} path="/admin/browser_errors" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("AdminBrowserErrors", () => {
  afterEach(() => vi.restoreAllMocks())

  it("renders compact filter chips for browser error searches", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      current_revision: "abc123",
      revision_scope: "current",
      filters: {},
      timeline: [],
      pagination: {
        page: 1,
        per_page: 50,
        has_next_page: false,
        has_previous_page: false,
        next_page: null,
        previous_page: null
      },
      events: []
    }))

    renderRoute()

    expect(await screen.findByRole("heading", { name: "Browser errors" })).toBeInTheDocument()
    expect(screen.getByText("Search is")).toBeInTheDocument()
    expect(screen.getByText("Since is")).toBeInTheDocument()
    expect(screen.getByText("Revision is")).toBeInTheDocument()
    expect(screen.getByDisplayValue("24h")).toBeInTheDocument()
    expect(screen.getByDisplayValue("Current SHA")).toBeInTheDocument()
    expect(await screen.findByText("No browser errors recorded.")).toBeInTheDocument()
    expect(String(fetchSpy.mock.calls[0][0])).toContain("/api/v1/app/admin/browser_errors?since=24h&revision_scope=current&per_page=50")
  })
})
