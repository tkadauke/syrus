import { render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it } from "vitest"
import type { DashboardJobItem, DashboardPayload } from "../api/dashboard"
import { DashboardTable } from "./Dashboard"

// Only the fields read by the "issue"/title cell PR link + external badge path.
function jobItem(id: number, overrides: Partial<DashboardJobItem> = {}): DashboardJobItem {
  return {
    id,
    type: "job",
    epic: null,
    landing_queue_entry_key: null,
    title: `Job ${id}`,
    title_pending: false,
    needs_attention: false,
    owner_badge: null,
    tags: [],
    source_chat: null,
    manual_paused: false,
    retry_state: null,
    start_blocked_reason: null,
    issue_number: null,
    issue_url: null,
    pr_number: 17,
    pr_url: "https://github.com/acme/widgets/pull/17",
    pr_is_external: false,
    paths: { job_path: `/jobs/${id}`, source_path: `/jobs/${id}` },
    ...overrides
  } as unknown as DashboardJobItem
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
      sort: { column: "created_at", direction: "desc" },
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
      sort_columns: ["created_at"],
      sort_directions: ["asc", "desc"],
      columns: {
        required: [{ key: "issue", title: "Issue" }],
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

describe("external PR marking in the dashboard job list", () => {
  it("does not show an external badge for a PR Syrus opened itself", () => {
    renderTable([ jobItem(1, { pr_is_external: false }) ])
    expect(screen.getByText("PR #17")).toBeInTheDocument()
    expect(screen.queryByText("External")).toBeNull()
  })

  it("shows an external badge next to the PR link when it was not opened by Syrus", () => {
    renderTable([ jobItem(2, { pr_is_external: true }) ])
    expect(screen.getByText("PR #17")).toBeInTheDocument()
    expect(screen.getByText("External")).toBeInTheDocument()
  })
})
