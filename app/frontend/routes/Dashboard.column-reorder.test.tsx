import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "../testSupport"
import type { DashboardPayload } from "../api/dashboard"
import { DashboardToolbar } from "./Dashboard"

function buildPayload(overrides: Partial<DashboardPayload> = {}): DashboardPayload {
  return {
    subject: "job",
    view: "list",
    page: 1,
    per_page: 25,
    total: 0,
    total_pages: 1,
    counts: { jobs: 0, epics: 0, workflows: 0 },
    preferences: {
      sort: { column: "created_at", direction: "desc" },
      visible_columns: ["priority", "status", "repository"],
      kanban_lanes: [],
      ownership_scope: "team",
      owner_user_id: null,
      owner_id: null,
      raw: {}
    },
    controls: {
      views: ["list", "kanban"],
      ownership_scopes: [],
      owners: [],
      sort_columns: ["created_at"],
      sort_directions: ["asc", "desc"],
      columns: {
        required: [],
        optional: [
          { key: "priority", title: "Priority" },
          { key: "status", title: "Status" },
          { key: "repository", title: "Repository" }
        ]
      },
      kanban_lanes: [],
      filter_schema: [],
      filter_suggestions: []
    },
    landing_queue: { visible: false, paused: false, toggle_path: "" },
    ownership_scope: { scope: "team", owner_user_id: null, owner_user: null },
    ownership: { scope: "team", owner_id: null, team_user_count: 1, badges_visible: false },
    smart_folders: [],
    active_smart_folder_id: null,
    items: [],
    lanes: [],
    kanban_limit: null,
    paths: { dashboard_path: "/dashboard/jobs", dashboard_jobs_path: "/dashboard/jobs", dashboard_epics_path: "/dashboard/epics", dashboard_workflows_path: "/dashboard/workflows", new_epic_path: "/epics/new", new_job_path: "/jobs/new", app_dashboard_path: "/api/v1/app/dashboard" },
    ...overrides
  }
}

function renderToolbar(payload: DashboardPayload) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={queryClient}>
      <MemoryRouter>
        <DashboardToolbar payload={payload} pathname="/dashboard/jobs" search="" showConfiguration isDesktop />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function dataTransfer() {
  return { dropEffect: "", effectAllowed: "", getData: vi.fn(), setData: vi.fn() }
}

describe("Dashboard column visibility menu", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("sends a move-up reorder as visible_columns in the requested order", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      jsonResponse({ message: "ok", dashboard_preferences: {} })
    )

    renderToolbar(buildPayload())

    fireEvent.click(screen.getByRole("button", { name: "Columns" }))
    fireEvent.click(screen.getByLabelText("Move Repository up"))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/dashboard/preferences", expect.objectContaining({ method: "PATCH" })))
    const request = fetchSpy.mock.calls.find((call) => String(call[0]) === "/api/v1/app/dashboard/preferences")
    expect(JSON.parse(String(request?.[1]?.body))).toEqual({
      subject: "job",
      visible_columns: ["priority", "repository", "status"]
    })
  })

  it("sends a dragged reorder as visible_columns in the requested order", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      jsonResponse({ message: "ok", dashboard_preferences: {} })
    )

    renderToolbar(buildPayload())

    fireEvent.click(screen.getByRole("button", { name: "Columns" }))
    const priorityRow = screen.getByLabelText("Priority").closest("label")!.parentElement!
    const repositoryRow = screen.getByLabelText("Repository").closest("label")!.parentElement!
    const transfer = dataTransfer()

    fireEvent.dragStart(priorityRow, { dataTransfer: transfer })
    fireEvent.dragOver(repositoryRow, { dataTransfer: transfer })
    fireEvent.drop(repositoryRow, { dataTransfer: transfer })

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/dashboard/preferences", expect.objectContaining({ method: "PATCH" })))
    const request = fetchSpy.mock.calls.find((call) => String(call[0]) === "/api/v1/app/dashboard/preferences")
    expect(JSON.parse(String(request?.[1]?.body))).toEqual({
      subject: "job",
      visible_columns: ["status", "repository", "priority"]
    })
  })

  it("toggling a column off still sends the remaining columns in their current order", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      jsonResponse({ message: "ok", dashboard_preferences: {} })
    )

    renderToolbar(buildPayload())

    fireEvent.click(screen.getByRole("button", { name: "Columns" }))
    fireEvent.click(screen.getByLabelText("Status"))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/dashboard/preferences", expect.objectContaining({ method: "PATCH" })))
    const request = fetchSpy.mock.calls.find((call) => String(call[0]) === "/api/v1/app/dashboard/preferences")
    expect(JSON.parse(String(request?.[1]?.body))).toEqual({
      subject: "job",
      visible_columns: ["priority", "repository"]
    })
  })
})
