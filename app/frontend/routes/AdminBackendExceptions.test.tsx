import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
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

  it("renders dashboard-style filter chips for backend exception searches", async () => {
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
      events: [backendExceptionEvent()]
    }))

    renderRoute()

    expect(await screen.findByRole("heading", { name: "Backend exceptions" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Since is 24h" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Revision is Current SHA" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Per page is 50" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "+ Add filter" })).toBeInTheDocument()
    expect(await screen.findByText("undefined method map")).toBeInTheDocument()
    expect(String(fetchSpy.mock.calls[0][0])).toBe("/api/v1/app/admin/backend_exceptions")
  })

  it("sorts by a clicked column header and reverses direction on a second click", async () => {
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
      events: [backendExceptionEvent()]
    }))

    renderRoute()
    await screen.findByText("undefined method map")

    fireEvent.click(screen.getByRole("button", { name: /Error/i }))

    await waitFor(() => {
      expect(fetchSpy.mock.calls.some((call) => String(call[0]).includes("sort=error&direction=asc"))).toBe(true)
    })

    fireEvent.click(screen.getByRole("button", { name: /Error/i }))

    await waitFor(() => {
      expect(fetchSpy.mock.calls.some((call) => String(call[0]).includes("sort=error&direction=desc"))).toBe(true)
    })
  })
})

function backendExceptionEvent() {
  return {
    id: 1,
    occurred_at: "2026-08-17T20:46:35Z",
    app_revision: "abc123",
    fingerprint: "fp",
    source: "action_controller",
    role: "web",
    hostname: "host-a",
    pid: 123,
    request_id: "req-1",
    exception_class: "NoMethodError",
    message: "undefined method map",
    backtrace: null,
    controller: "JobsController",
    action: "show",
    method: "GET",
    path: "/jobs/3188",
    status: 500,
    job_class: null,
    active_job_id: null,
    queue_name: null,
    executions: null,
    job_id: 3188,
    job_slug: "JOB-3188",
    workflow_id: null,
    run_id: null,
    metadata: {},
    actions: []
  }
}
