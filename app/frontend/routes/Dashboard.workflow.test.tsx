import { render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it } from "vitest"
import type { DashboardPayload, DashboardWorkflowItem } from "../api/dashboard"
import { DashboardTable } from "./Dashboard"

function workflowItem(id: number, jobTitle: string): DashboardWorkflowItem {
  return {
    id,
    type: "workflow",
    slug: `WF-${id}`,
    path: `/workflows/${id}`,
    state: "running",
    trigger_kind: "initial",
    agent_provider: "claude",
    created_at: null,
    updated_at: null,
    started_at: null,
    finished_at: null,
    cleaned_up_at: null,
    steps_count: 3,
    job: {
      id: id * 10,
      title: jobTitle,
      state: "running",
      repository: { id: 1, slug: "acme/widgets", repository_path: "/repositories/1" },
      owner_user: null,
      owner_badge: null,
      path: `/jobs/${id * 10}`
    }
  }
}

function buildPayload(items: DashboardWorkflowItem[]): DashboardPayload {
  return {
    subject: "workflow",
    view: "list",
    page: 1,
    per_page: 25,
    total: items.length,
    total_pages: 1,
    counts: { jobs: 0, epics: 0, workflows: items.length },
    ownership_scope: { scope: "team", owner_user_id: null, owner_user: null },
    preferences: {
      sort: { column: "title", direction: "desc" },
      visible_columns: [],
      kanban_lanes: [],
      ownership_scope: "team",
      owner_user_id: null,
      owner_id: null,
      raw: {}
    },
    filter: null,
    controls: {
      views: ["list"],
      ownership_scopes: [
        { value: "mine", label: "Mine" },
        { value: "team", label: "Team" },
        { value: "claimable", label: "Claimable" },
        { value: "user", label: "User" }
      ],
      owners: [],
      sort_columns: ["title", "state", "finished_at"],
      sort_directions: ["asc", "desc"],
      columns: {
        required: [{ key: "workflow", title: "Workflow" }, { key: "job", title: "Job" }, { key: "trigger", title: "Trigger" }, { key: "state", title: "State" }, { key: "started", title: "Started" }, { key: "finished", title: "Finished" }, { key: "agent", title: "Agent" }],
        optional: []
      },
      kanban_lanes: [],
      filter_schema: [],
      filter_suggestions: []
    },
    landing_queue: { visible: false, paused: false, toggle_path: "", entries: [] },
    ownership: { scope: "team", owner_id: null, team_user_count: 3, badges_visible: true },
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

function renderTable(payload: DashboardPayload) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={queryClient}>
      <MemoryRouter>
        <DashboardTable payload={payload} prefix="" setupStatus={null} />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("DashboardTable workflow subject", () => {
  it("renders workflow items with their job titles", () => {
    const items = [
      workflowItem(1, "Build aqueduct"),
      workflowItem(2, "Chart forum")
    ]
    renderTable(buildPayload(items))

    expect(screen.getByText("Build aqueduct")).toBeInTheDocument()
    expect(screen.getByText("Chart forum")).toBeInTheDocument()
  })

  it("shows empty state when no workflows match", () => {
    const payload = buildPayload([])
    payload.total = 5 // items exist but none match this filter
    renderTable(payload)

    expect(screen.getByText(/no workflows match/i)).toBeInTheDocument()
  })

})
