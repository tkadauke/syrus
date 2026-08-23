import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi } from "vitest"
import { jsonResponse } from "../testSupport"
import type { DashboardPayload, DashboardEpicItem, DashboardJobItem } from "../api/dashboard"
import { DashboardTable, LegacyEpicsBanner } from "./Dashboard"

function client() {
  return new QueryClient({ defaultOptions: { queries: { retry: false } } })
}

describe("Dashboard simple mode", () => {
  it("renders every Job with its own status shown directly, not an epic rollup", () => {
    render(
      <QueryClientProvider client={client()}>
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

  it("shows a Preview & Approve action for an implemented job that can be previewed and approved", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({ preview: null }))

    const payload = simpleDashboardPayload()
    payload.items = [
      simpleJob({
        id: 5,
        title: "Add invoice PDF export",
        state: "implemented",
        summary_state: "implemented",
        can_start_preview: true,
        can_approve: true,
        paths: {
          job_path: "/jobs/5",
          source_path: "/jobs/5/source",
          app_approve_path: "/api/v1/app/jobs/5/approve",
          app_preview_path: "/api/v1/app/jobs/5/preview",
          app_preview_logs_path: "/api/v1/app/jobs/5/preview/logs"
        }
      })
    ]

    render(
      <QueryClientProvider client={client()}>
        <MemoryRouter>
          <DashboardTable payload={payload} prefix="" setupStatus={null as never} />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByText("Ready for your review")).toBeInTheDocument()
    await waitFor(() => expect(screen.getByRole("button", { name: "Start Preview" })).toBeInTheDocument())
    expect(screen.getByRole("button", { name: "Looks good, approve" })).toBeInTheDocument()
  })

  it("does not show a Preview & Approve action for a job that cannot yet be previewed or approved", () => {
    const payload = simpleDashboardPayload()
    payload.items = [simpleJob({ id: 6, title: "Still in progress", state: "running", summary_state: "running" })]

    render(
      <QueryClientProvider client={client()}>
        <MemoryRouter>
          <DashboardTable payload={payload} prefix="" setupStatus={null as never} />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.queryByText("Ready for your review")).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Looks good, approve" })).not.toBeInTheDocument()
  })

  it("renders the legacy epic list unchanged when subject is epic, instead of the job list", () => {
    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter>
          <DashboardTable payload={simpleEpicsDashboardPayload()} prefix="" setupStatus={null as never} />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const link = screen.getByRole("link", { name: /legacy checkout revamp/i })
    expect(link).toHaveAttribute("href", "/epics/9")
    expect(screen.queryByText("Ship the invoice PDF export")).not.toBeInTheDocument()
  })
})

describe("LegacyEpicsBanner", () => {
  it("explains that these are older features and new requests appear on the main dashboard", () => {
    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter>
          <LegacyEpicsBanner />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByRole("status")).toHaveTextContent(/older, multi-step features/i)
    expect(screen.getByRole("status")).toHaveTextContent(/individual tasks on the main dashboard/i)
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

function simpleEpicItem(overrides: Partial<DashboardEpicItem>): DashboardEpicItem {
  return {
    type: "epic",
    id: 9,
    number: 9,
    display_number: "EPIC-9",
    title: "Legacy checkout revamp",
    description: "",
    state: "in_progress",
    simple_status: "working_on_it",
    stuck: false,
    all_jobs_closed: false,
    owner: null,
    owned_by_current_user: false,
    claimable: false,
    owner_badge: null,
    claimed_at: null,
    auto_approve_mode: "off",
    owner_user_id: null,
    owner_status: "unclaimed",
    jobs_count: 2,
    landed_jobs_count: 0,
    job_state_counts: {},
    max_commits_behind_base: null,
    created_at: null,
    updated_at: "2026-07-30T12:00:00Z",
    done_at: null,
    archived_at: null,
    repository: { id: 1, slug: "acme/widgets", repository_path: "/repositories/1" },
    paths: {
      epic_path: "/epics/9",
      edit_epic_path: "/epics/9/edit",
      app_state_path: "/api/v1/app/epics/9/state",
      app_claim_path: "/api/v1/app/epics/9/claim",
      app_unclaim_path: "/api/v1/app/epics/9/unclaim"
    },
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

function simpleEpicsDashboardPayload(): DashboardPayload {
  const base = simpleDashboardPayload()
  return {
    ...base,
    subject: "epic",
    counts: { jobs: 0, epics: 1, workflows: 0 },
    items: [simpleEpicItem({})]
  }
}
