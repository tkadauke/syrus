import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "../testSupport"
import { AdminBackendExceptions } from "./AdminBackendExceptions"

function renderRoute() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/admin/backend_exceptions"]}>
        <Routes>
          <Route element={<AdminBackendExceptions />} path="/admin/backend_exceptions" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("AdminBackendExceptions", () => {
  afterEach(() => vi.restoreAllMocks())

  it("renders compact filter chips for backend exception searches", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      current_revision: "abc123",
      revision_scope: "current",
      filters: {},
      sources: ["active_job", "action_controller"],
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

    expect(await screen.findByRole("heading", { name: "Backend exceptions" })).toBeInTheDocument()
    expect(screen.getByText("Search is")).toBeInTheDocument()
    expect(screen.getByText("Source is")).toBeInTheDocument()
    expect(screen.getByText("Revision is")).toBeInTheDocument()
    expect(screen.getByDisplayValue("All sources")).toBeInTheDocument()
    expect(screen.getByDisplayValue("Current SHA")).toBeInTheDocument()
    expect(await screen.findByText("No backend exceptions recorded.")).toBeInTheDocument()
    expect(String(fetchSpy.mock.calls[0][0])).toContain("/api/v1/app/admin/backend_exceptions?since=24h&revision_scope=current&per_page=50")
  })
})
