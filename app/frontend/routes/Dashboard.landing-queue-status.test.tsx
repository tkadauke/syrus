import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it } from "vitest"
import type { DashboardJobItem, DashboardPayload } from "../api/dashboard"
import { DashboardTable } from "./Dashboard"

function jobItem(overrides: Partial<DashboardJobItem> = {}): DashboardJobItem {
  const id = overrides.id ?? 1
  return {
    type: "job",
    id,
    kind: "direct",
    title: `Job ${id}`,
    state: "approved",
    summary_state: "approved",
    validity: "valid",
    priority: "medium",
    agent_provider: "codex",
    total_cost_usd: null,
    issue_number: null,
    issue_url: null,
    branch_name: null,
    pr_number: 100 + id,
    active_workflow_trigger_kind: null,
    latest_workflow_id: null,
    latest_workflow_trigger_kind: null,
    pr_url: null,
    latest_workflow_state: "approved",
    landing_queue_position: id,
    landing_queue_blocked_reason: null,
    landing_queue_wait_reason: null,
    landing_queue_entry_key: `job:${id}`,
    blocked_reason: null,
    created_at: null,
    updated_at: null,
    started_at: null,
    finished_at: null,
    approved_at: "2026-08-04T12:00:00Z",
    owner_user_id: null,
    owner_user: null,
    claimed_at: null,
    claimed_by_user: null,
    claimed_by_current_user: false,
    dependencies_overridden_at: null,
    last_feedback_addressed_at: null,
    last_seen_comment_at: null,
    pr_mergeable_checked_at: null,
    commits_behind_base: null,
    workflows_count: 1,
    repository: { id: 1, slug: "acme/widgets", repository_path: "/repositories/1" },
    epic: null,
    owner_badge: null,
    tags: [],
    source_chat: null,
    needs_attention: false,
    needs_attention_reason: null,
    start_blocked_reason: null,
    start_blocked_at: null,
    start_blocked_details: null,
    paths: { job_path: `/jobs/${id}`, source_path: `/jobs/${id}/source` },
    ...overrides
  }
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
      sort: { column: "landing_queue_position", direction: "asc" },
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
      sort_columns: ["landing_queue_position", "created_at"],
      sort_directions: ["asc", "desc"],
      columns: {
        required: [
          { key: "checkbox", title: "Checkbox" },
          { key: "landing_queue_position", title: "Queue" },
          { key: "landing_queue_wait_reason", title: "Queue status" },
          { key: "issue", title: "Issue" }
        ],
        optional: []
      },
      kanban_lanes: [],
      filter_schema: [],
      filter_suggestions: []
    },
    landing_queue: { visible: true, paused: false, toggle_path: "", entries: [] },
    ownership: { scope: "mine", owner_id: null, team_user_count: 1, badges_visible: false },
    smart_folders: [
      { id: 7, name: "Landing queue", key: "landing_queue", kind: "builtin", position: 1, subject_type: "job", visibility: "when_present", count: items.length, active: true, filter: {}, attention_preset: "landing_queue", path: "/dashboard/jobs?smart_folder_id=7" }
    ],
    active_smart_folder_id: 7,
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
  return render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter>
        <DashboardTable payload={buildPayload(items)} prefix="" setupStatus={null} />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("landing queue status column", () => {
  it("renders ordinary queue waits with neutral styling under Queue status", () => {
    renderTable([
      jobItem({
        id: 1,
        landing_queue_wait_reason: { key: "waiting_epic_merge_train" },
        landing_queue_entry_key: "epic:1"
      })
    ])

    expect(screen.getByText("Queue status")).toBeInTheDocument()
    const status = screen.getByText("Waiting for Epic merge-train").closest("span")
    expect(status?.className).toContain("gray")
    expect(status?.className).not.toContain("red")
  })

  it("renders true landing blockers with warning styling in the same column", () => {
    renderTable([
      jobItem({
        id: 2,
        landing_queue_blocked_reason: { key: "landing_paused" },
        landing_queue_wait_reason: null
      })
    ])

    const status = screen.getByText("Landing paused").closest("span")
    expect(status?.className).toContain("red")
  })
})
