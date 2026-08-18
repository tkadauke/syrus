import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
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

  it("renders dashboard-style filter chips for browser error searches", async () => {
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
      events: [browserErrorEvent()]
    }))

    renderRoute()

    expect(await screen.findByRole("heading", { name: "Browser errors" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Since is 24h" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Revision is Current SHA" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Per page is 50" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "+ Add filter" })).toBeInTheDocument()
    expect(await screen.findByText("undefined is not an object")).toBeInTheDocument()
    expect(String(fetchSpy.mock.calls[0][0])).toContain("/api/v1/app/admin/browser_errors?since=24h&revision_scope=current&per_page=50")
  })

  it("sorts by a clicked column header and reverses direction on a second click", async () => {
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
      events: [browserErrorEvent()]
    }))

    renderRoute()
    await screen.findByText("undefined is not an object")

    fireEvent.click(screen.getByRole("button", { name: /Path/i }))

    await waitFor(() => {
      expect(fetchSpy.mock.calls.some((call) => String(call[0]).includes("sort=path&direction=asc"))).toBe(true)
    })

    fireEvent.click(screen.getByRole("button", { name: /Path/i }))

    await waitFor(() => {
      expect(fetchSpy.mock.calls.some((call) => String(call[0]).includes("sort=path&direction=desc"))).toBe(true)
    })
  })
})

function browserErrorEvent() {
  return {
    id: 1,
    occurred_at: "2026-08-17T20:46:35Z",
    app_revision: "abc123",
    fingerprint: "fp",
    name: "TypeError",
    message: "undefined is not an object",
    stack: null,
    component_stack: null,
    url: "https://syrus.example/jobs/3188",
    path: "/jobs/3188",
    route_id: "job",
    route_params: {},
    trace_id: null,
    user_agent: "Safari",
    viewport: {},
    feature_flags: {},
    recent_api_requests: [],
    recent_errors: [],
    metadata: {},
    actions: [],
    user: { id: 1, display_name: "Thomas", email_address: "thomas@example.com" }
  }
}
