import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "../testSupport"
import { AdminMaintenanceTaskDetail } from "./AdminMaintenanceTasks"

function renderDetailRoute(initialEntry = "/app-shell/admin/maintenance_tasks/1?log_page=2") {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={[initialEntry]}>
        <Routes>
          <Route element={<AdminMaintenanceTaskDetail />} path="/app-shell/admin/maintenance_tasks/:id" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("AdminMaintenanceTaskDetail", () => {
  afterEach(() => vi.restoreAllMocks())

  it("renders paginated task log controls and a mobile-friendly event list", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(taskPayload()))

    renderDetailRoute()

    expect(await screen.findByRole("heading", { name: "Backfill Agent records" })).toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/admin/maintenance_tasks/1?log_page=2",
      expect.objectContaining({ credentials: "same-origin" })
    )
    expect(screen.getByText("Showing 101-105 of 105 log entries")).toBeInTheDocument()
    expect(screen.getByText("Page 2 of 2")).toHaveClass("whitespace-nowrap")
    expect(screen.getByRole("link", { name: "Previous" })).toHaveAttribute("href", "/app-shell/admin/maintenance_tasks/1")
    expect(screen.getByText("Next")).toHaveClass("text-gray-400")
    expect(screen.getByTestId("maintenance-task-log-mobile")).toHaveClass("sm:hidden")
  })
})

function taskPayload() {
  return {
    id: 1,
    definition_key: "agents_backfill",
    task_key: "agents_backfill",
    state: "running",
    recurrence: "one_off",
    category: "backfill",
    title: "Backfill Agent records",
    summary: "Creates Agent records for historical work.",
    trigger_kind: "manual",
    trigger_key: "spec",
    required_role: "admin",
    current_step_key: "runs",
    current_step_title: "Create Agent rows",
    total_units: 105,
    completed_units: 105,
    failed_units: 0,
    progress_percent: 100,
    eta_seconds: null,
    started_at: "2026-09-13T10:00:00Z",
    finished_at: null,
    paused_at: null,
    cancelled_at: null,
    dismissed_at: null,
    last_error: null,
    pending_reason: null,
    documentation: "Backfills historical Agent rows.",
    steps: [],
    paths: { admin: "/admin/maintenance_tasks/1", api: "/api/v1/app/admin/maintenance_tasks/1" },
    events: [
      {
        id: 101,
        level: "progress",
        step_key: "runs",
        step_title: "Create Agent rows",
        message: "Created 1 Run Agent row.",
        units_done: 101,
        units_total: 105,
        created_at: "2026-09-13T10:05:00Z"
      }
    ],
    events_pagination: {
      page: 2,
      per_page: 100,
      total_events: 105,
      total_pages: 2,
      first_item: 101,
      last_item: 105,
      previous_page: 1,
      next_page: null,
      has_previous_page: true,
      has_next_page: false
    }
  }
}
