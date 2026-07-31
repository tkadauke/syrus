import { render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it } from "vitest"
import type { DashboardJobItem, DashboardPayload } from "../api/dashboard"
import { DashboardTable } from "./Dashboard"

function jobItem(id: number, label: string | null): DashboardJobItem {
  return {
    id,
    type: "job",
    epic: null,
    landing_queue_entry_key: null,
    latest_deployment_stage: label ? { name: "staging", label, reached_at: "2026-07-30T12:00:00Z" } : null,
    paths: { job_path: `/jobs/JOB-${id}`, source_path: `/jobs/JOB-${id}/source` }
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
        required: [{ key: "deployment", title: "Deployment" }],
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

describe("deployment column rendering", () => {
  it("renders the latest deployment stage as a job link", () => {
    renderTable([ jobItem(12, "On Staging") ])
    const link = screen.getByRole("link", { name: "On Staging" })

    expect(link.getAttribute("href")).toBe("/jobs/JOB-12")
  })

  it("renders a dash when no deployment stage has been reached", () => {
    renderTable([ jobItem(13, null) ])

    expect(screen.getByText("—")).toBeTruthy()
  })
})
