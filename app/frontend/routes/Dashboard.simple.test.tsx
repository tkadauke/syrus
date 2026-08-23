import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it } from "vitest"
import type { DashboardPayload, DashboardJobItem } from "../api/dashboard"
import { DashboardTable } from "./Dashboard"

describe("Dashboard simple mode", () => {
  it("renders every Job with its own status shown directly, not an epic rollup", () => {
    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter>
          <DashboardTable payload={simpleDashboardPayload()} prefix="" setupStatus={null as never} />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByText("Checkout polish")).toBeInTheDocument()
    expect(screen.getByText("running")).toBeInTheDocument()
    expect(screen.getByText("Ship the invoice PDF export")).toBeInTheDocument()
    expect(screen.getByText("closed")).toBeInTheDocument()
    expect(screen.getByText("Pr merged")).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: /checkout polish/i })).not.toBeInTheDocument()
    expect(screen.queryByText("Workflow")).not.toBeInTheDocument()
  })
})

function simpleJob(overrides: Partial<DashboardJobItem>): DashboardJobItem {
  return {
    type: "job",
    id: 1,
    kind: "direct",
    title: "Untitled job",
    state: "open",
    summary_state: "open",
    closure_reason: null,
    validity: "valid",
    priority: "medium",
    agent_provider: "codex",
    total_cost_usd: null,
    issue_number: null,
    issue_url: null,
    branch_name: null,
    pr_number: null,
    active_workflow_trigger_kind: null,
    latest_workflow_id: null,
    latest_workflow_trigger_kind: null,
    pr_url: null,
    latest_workflow_state: "queued",
    landing_queue_position: null,
    landing_queue_blocked_reason: null,
    landing_queue_wait_reason: null,
    landing_queue_entry_key: null,
    blocked_reason: null,
    created_at: null,
    updated_at: "2026-07-30T12:00:00Z",
    started_at: null,
    finished_at: null,
    approved_at: null,
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
    start_blocked_next_check_at: null,
    start_blocked_count: null,
    start_blocked_details: null,
    paths: { job_path: `/jobs/${overrides.id ?? 1}`, source_path: `/jobs/${overrides.id ?? 1}/source` },
    ...overrides
  }
}

function simpleDashboardPayload(): DashboardPayload {
  return {
    simple_mode: true,
    subject: "job",
    view: "list",
    page: 1,
    per_page: 25,
    total: 2,
    total_pages: 1,
    counts: { jobs: 2, epics: 1, workflows: 1 },
    preferences: { sort: { column: "created_at", direction: "desc" }, visible_columns: [], kanban_lanes: [], ownership_scope: "team", owner_user_id: null, owner_id: null, raw: {} },
    controls: { views: ["list"], ownership_scopes: [], owners: [], sort_columns: ["created_at"], sort_directions: ["asc", "desc"], columns: { required: [], optional: [] }, kanban_lanes: [], filter_schema: [], filter_suggestions: [] },
    landing_queue: { visible: false, paused: false, toggle_path: "" },
    ownership_scope: { scope: "team", owner_user_id: null, owner_user: null },
    ownership: { scope: "team", owner_id: null, team_user_count: 1, badges_visible: false },
    smart_folders: [],
    active_smart_folder_id: null,
    items: [
      simpleJob({ id: 2, kind: "issue", title: "Checkout polish", state: "running", summary_state: "running" }),
      simpleJob({ id: 3, kind: "direct", title: "Ship the invoice PDF export", state: "closed", summary_state: "closed", closure_reason: "pr_merged" })
    ],
    lanes: [],
    kanban_limit: null,
    paths: { dashboard_path: "/dashboard/jobs", dashboard_jobs_path: "/dashboard/jobs", dashboard_epics_path: "/dashboard/epics", dashboard_workflows_path: "/dashboard/workflows", new_epic_path: "/epics/new", new_job_path: "/jobs/new", app_dashboard_path: "/api/v1/app/dashboard" }
  }
}
