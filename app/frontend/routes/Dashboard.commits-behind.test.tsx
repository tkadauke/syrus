import { render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it } from "vitest"
import type { DashboardJobItem, DashboardPayload } from "../api/dashboard"
import { DashboardTable } from "./Dashboard"

// Only `id`, `commits_behind_base`, `type`, `epic`, and `landing_queue_entry_key`
// are read by the commits_behind_base cell path.
function jobItem(id: number, commits_behind_base: number | null): DashboardJobItem {
  return { id, commits_behind_base, type: "job", epic: null, landing_queue_entry_key: null } as unknown as DashboardJobItem
}

function buildPayload(items: DashboardJobItem[]): DashboardPayload {
  return {
    subject: "job",
    view: "list",
    page: 1,
    per_page: 25,
    total: items.length,
    total_pages: 1,
    counts: { jobs: items.length, epics: 0, workflows: 0 },
    ownership_scope: { scope: "mine", owner_user_id: null, owner_user: null },
    preferences: {
      sort: { column: "commits_behind_base", direction: "asc" },
      visible_columns: [],
      kanban_lanes: [],
      ownership_scope: "mine",
      owner_user_id: null,
      owner_id: null,
      raw: {}
    },
    filter: null,
    controls: {
      views: ["list"],
      ownership_scopes: [],
      owners: [],
      sort_columns: ["commits_behind_base", "created_at"],
      sort_directions: ["asc", "desc"],
      columns: {
        required: [{ key: "commits_behind_base", title: "Behind" }],
        optional: []
      },
      kanban_lanes: [],
      filter_schema: [],
      filter_suggestions: []
    },
    landing_queue: { visible: false, paused: false, toggle_path: "", entries: [] },
    ownership: { scope: "mine", owner_id: null, team_user_count: 1, badges_visible: false },
    smart_folders: [],
    active_smart_folder_id: null,
    items,
    lanes: [],
    kanban_limit: null,
    paths: {
      dashboard_path: "/dashboard",
      dashboard_jobs_path: "/dashboard/jobs",
      dashboard_epics_path: "/dashboard/epics",
      dashboard_workflows_path: "/dashboard/workflows",
      new_epic_path: "/epics/new",
      new_job_path: "/jobs/new",
      app_dashboard_path: "/api/v1/app/dashboard"
    }
  }
}

function renderTable(items: DashboardJobItem[]) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={queryClient}>
      <MemoryRouter>
        <DashboardTable payload={buildPayload(items)} prefix="" setupStatus={null} />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("commits_behind_base column rendering", () => {
  it("renders no badge for 0 commits behind", () => {
    renderTable([ jobItem(1, 0) ])
    expect(screen.queryByLabelText(/commits behind base/)).toBeNull()
  })

  it("renders an amber badge for a small number of commits behind (10-19)", () => {
    renderTable([ jobItem(2, 10) ])
    const badge = screen.getByLabelText("10 commits behind base")
    expect(badge.className).toContain("bg-warning-surface")
  })

  it("renders a red badge for a moderate number of commits behind (20+)", () => {
    renderTable([ jobItem(3, 25) ])
    const badge = screen.getByLabelText("25 commits behind base")
    expect(badge.className).toContain("bg-danger-surface")
  })

  it("renders a red badge for many commits behind (50+)", () => {
    renderTable([ jobItem(4, 75) ])
    const badge = screen.getByLabelText("75 commits behind base")
    expect(badge.className).toContain("bg-danger-surface")
  })

  it("renders nothing when commits_behind_base is null", () => {
    renderTable([ jobItem(5, null) ])
    // The cell renders but no badge text should appear
    expect(screen.queryByRole("generic", { name: /\d+/ })).toBeNull()
  })
})
