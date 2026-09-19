import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it } from "vitest"
import type { DashboardPayload } from "../api/dashboard"
import { DashboardCreateActions, DashboardToolbar, SubjectTabs } from "./Dashboard"

const MD_HEIGHT_CLASS = "h-[var(--control-height-md)]"

function client() {
  return new QueryClient({ defaultOptions: { queries: { retry: false } } })
}

function buildPayload(overrides: Partial<DashboardPayload> = {}): DashboardPayload {
  return {
    simple_mode: false,
    subject: "job",
    view: "list",
    page: 1,
    per_page: 25,
    total: 0,
    total_pages: 1,
    counts: { jobs: 0, epics: 0, workflows: 0 },
    preferences: { sort: { column: "created_at", direction: "desc" }, visible_columns: [], kanban_lanes: [], ownership_scope: "team", owner_user_id: null, owner_id: null, raw: {} },
    controls: { views: ["list", "kanban", "dependencies"], ownership_scopes: [], owners: [], sort_columns: ["created_at"], sort_directions: ["asc", "desc"], columns: { required: [], optional: [{ key: "priority", title: "Priority" }] }, kanban_lanes: [], filter_schema: [], filter_suggestions: [] },
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

function renderHeader(payload: DashboardPayload) {
  render(
    <QueryClientProvider client={client()}>
      <MemoryRouter>
        <div className="flex items-center gap-3">
          <DashboardToolbar payload={payload} pathname="/dashboard/jobs" search="" showConfiguration isDesktop />
          <DashboardCreateActions payload={payload} prefix="" />
        </div>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("Dashboard header control heights", () => {
  it("sizes the columns icon button, view switcher links, and New Epic/New Job links to the same md control height", () => {
    renderHeader(buildPayload())

    const columnsButton = screen.getByRole("button", { name: "Columns" })
    const viewLinks = ["list", "kanban", "dependencies"].map((view) => screen.getByRole("link", { name: view }))
    const newEpicLink = screen.getByRole("link", { name: "New Epic" })
    const newJobLink = screen.getByRole("link", { name: "New Job" })

    for (const control of [columnsButton, ...viewLinks, newEpicLink, newJobLink]) {
      expect(control.className).toContain(MD_HEIGHT_CLASS)
    }
    // The icon button must not also carry the competing `sm` fixed height.
    expect(columnsButton.className).not.toContain("h-[var(--control-height-sm)]")
  })

  it("sizes the mobile subject tabs (Epics/Jobs/Workflows) to the same md control height", () => {
    render(
      <QueryClientProvider client={client()}>
        <MemoryRouter>
          <SubjectTabs pathname="/dashboard/jobs" payload={buildPayload()} prefix="" />
        </MemoryRouter>
      </QueryClientProvider>
    )

    for (const name of ["Epics", "Jobs", "Workflows"]) {
      expect(screen.getByRole("link", { name }).className).toContain(MD_HEIGHT_CLASS)
    }
  })
})
