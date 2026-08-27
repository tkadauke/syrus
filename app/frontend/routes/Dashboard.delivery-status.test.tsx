import { render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it } from "vitest"
import type { DashboardJobItem, DashboardPayload } from "../api/dashboard"
import { DashboardTable } from "./Dashboard"

// Covers the EPIC-268 delivery-status badge added to job rows: a small pill
// next to the job title for the "interesting" (non-default) delivery
// states, hidden for the two default states every job without delivery
// config resolves to.

function jobItem(overrides: Partial<DashboardJobItem> = {}): DashboardJobItem {
  return {
    id: 3,
    priority: "medium",
    type: "job",
    epic: null,
    landing_queue_entry_key: null,
    title: "Job 3",
    title_pending: false,
    needs_attention: false,
    owner_badge: null,
    pr_number: null,
    pr_url: null,
    summary_state: "succeeded",
    active_workflow_trigger_kind: null,
    repository: { id: 1, slug: "owner/repo", repository_path: "/repos/1" },
    paths: { job_path: "/jobs/3", source_path: "/jobs/3" },
    approved_at: "2026-07-31T12:00:00Z",
    created_at: "2026-07-31T10:00:00Z",
    started_at: "2026-07-31T11:00:00Z",
    kind: "direct",
    source_chat: null,
    state: "succeeded",
    tags: [],
    total_cost_usd: null,
    workflows_count: 2,
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
      sort: { column: "priority", direction: "asc" },
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
      sort_columns: ["priority", "created_at"],
      sort_directions: ["asc", "desc"],
      columns: {
        required: [{ key: "priority", title: "Priority" }, { key: "issue", title: "Issue" }],
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
  } as unknown as DashboardPayload
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

describe("delivery status badge", () => {
  it("renders a pill for waiting_for_upstream_approval", () => {
    renderTable([ jobItem({ delivery_status: "waiting_for_upstream_approval" }) ])

    expect(screen.getByText("Waiting for upstream approval")).toBeInTheDocument()
  })

  it("renders a pill for delivery_needs_attention", () => {
    renderTable([ jobItem({ delivery_status: "delivery_needs_attention" }) ])

    expect(screen.getByText("Delivery needs attention")).toBeInTheDocument()
  })

  it("does not render a pill for the default waiting_for_local_approval status", () => {
    renderTable([ jobItem({ delivery_status: "waiting_for_local_approval" }) ])

    expect(screen.queryByText("Waiting for local approval")).not.toBeInTheDocument()
  })

  it("does not render a pill for the default approved_for_local_landing status", () => {
    renderTable([ jobItem({ delivery_status: "approved_for_local_landing" }) ])

    expect(screen.queryByText("Approved for local landing")).not.toBeInTheDocument()
  })
})
