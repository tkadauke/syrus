import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { DashboardJobItem, DashboardPayload } from "../api/dashboard"
import type { LandingQueueBlockerJob } from "../api/jobs"
import { DashboardTable } from "./Dashboard"

// Only a handful of fields are read by the landing-queue group/blocker path.
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
    start_blocked_next_check_at: null,
    start_blocked_count: null,
    start_blocked_details: null,
    paths: { job_path: `/jobs/${id}`, source_path: `/jobs/${id}/source` },
    ...overrides
  }
}

function bundleBlockerJob(overrides: Partial<LandingQueueBlockerJob> = {}): LandingQueueBlockerJob {
  return {
    id: 99,
    title: "Bundled blocker",
    job_path: "/jobs/99",
    state: "landing",
    pr_number: 199,
    pr_path: "https://github.com/acme/widgets/pull/199",
    repository: { id: 1, slug: "acme/widgets", repository_path: "/repositories/1" },
    latest_workflow_state: "running",
    latest_workflow_trigger_kind: "auto_merge",
    latest_workflow_id: 5,
    started_at: null,
    created_at: null,
    bundle_other_job_count: 2,
    ...overrides
  }
}

function buildPayload(items: DashboardJobItem[], entries: DashboardPayload["landing_queue"]["entries"]): DashboardPayload {
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
    landing_queue: { visible: true, paused: false, toggle_path: "", entries },
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

function renderTable(items: DashboardJobItem[], entries: DashboardPayload["landing_queue"]["entries"]) {
  return render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter>
        <DashboardTable payload={buildPayload(items, entries)} prefix="" setupStatus={null} />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

const originalMatchMedia = Object.getOwnPropertyDescriptor(window, "matchMedia")

afterEach(() => {
  vi.restoreAllMocks()
  if (originalMatchMedia) {
    Object.defineProperty(window, "matchMedia", originalMatchMedia)
  } else {
    Reflect.deleteProperty(window, "matchMedia")
  }
})

function mockMediaQuery(matches: boolean) {
  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    writable: true,
    value: vi.fn((query: string) => ({
      matches,
      media: query,
      onchange: null,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      addListener: vi.fn(),
      removeListener: vi.fn(),
      dispatchEvent: vi.fn()
    }))
  })
}

describe("landing queue bundle attribution (desktop)", () => {
  it("labels a blocker that's part of a job bundle instead of standalone", () => {
    const items = [ jobItem({ id: 1 }) ]
    const entries = [
      { key: "job:1", position: 1, job_ids: [1], blocker_jobs: [bundleBlockerJob()], dependency_edges: [] }
    ]
    renderTable(items, entries)

    fireEvent.click(screen.getByText("1 blocker"))

    expect(screen.getByText("Bundled with 2 other jobs")).toBeInTheDocument()
    expect(screen.queryByText("standalone")).not.toBeInTheDocument()
  })

  it("uses singular copy for a bundle with exactly one other member", () => {
    const items = [ jobItem({ id: 1 }) ]
    const entries = [
      { key: "job:1", position: 1, job_ids: [1], blocker_jobs: [ bundleBlockerJob({ bundle_other_job_count: 1 }) ], dependency_edges: [] }
    ]
    renderTable(items, entries)

    fireEvent.click(screen.getByText("1 blocker"))

    expect(screen.getByText("Bundled with 1 other job")).toBeInTheDocument()
  })

  it("still labels an unbundled blocker as standalone", () => {
    const items = [ jobItem({ id: 1 }) ]
    const entries = [
      {
        key: "job:1",
        position: 1,
        job_ids: [1],
        blocker_jobs: [ bundleBlockerJob({ bundle_other_job_count: null, epic_id: null }) ],
        dependency_edges: []
      }
    ]
    renderTable(items, entries)

    fireEvent.click(screen.getByText("1 blocker"))

    expect(screen.getByText("standalone")).toBeInTheDocument()
  })

  it("draws a group boundary around a job-bundle landing unit", () => {
    const items = [ jobItem({ id: 1, landing_queue_entry_key: "job_bundle:9" }), jobItem({ id: 2, landing_queue_entry_key: "job:2" }) ]
    const entries = [
      { key: "job_bundle:9", position: 1, job_ids: [1], blocker_jobs: [], dependency_edges: [] },
      { key: "job:2", position: 2, job_ids: [2], blocker_jobs: [], dependency_edges: [] }
    ]
    renderTable(items, entries)

    const row = screen.getByText("Job 2").closest("tr")
    expect(row?.className).toContain("border-t-4")
  })
})

describe("landing queue bundle attribution (mobile)", () => {
  it("labels a blocker that's part of a job bundle instead of standalone", () => {
    mockMediaQuery(false)
    const items = [ jobItem({ id: 1 }) ]
    const entries = [
      { key: "job:1", position: 1, job_ids: [1], blocker_jobs: [bundleBlockerJob()], dependency_edges: [] }
    ]
    renderTable(items, entries)

    fireEvent.click(screen.getByText("1 blocker"))

    expect(screen.getByText("Bundled with 2 other jobs")).toBeInTheDocument()
    expect(screen.queryByText("standalone")).not.toBeInTheDocument()
  })

  it("draws a group boundary around a job-bundle landing unit", () => {
    mockMediaQuery(false)
    const items = [ jobItem({ id: 1, landing_queue_entry_key: "job_bundle:9" }), jobItem({ id: 2, landing_queue_entry_key: "job:2" }) ]
    const entries = [
      { key: "job_bundle:9", position: 1, job_ids: [1], blocker_jobs: [], dependency_edges: [] },
      { key: "job:2", position: 2, job_ids: [2], blocker_jobs: [], dependency_edges: [] }
    ]
    renderTable(items, entries)

    const article = screen.getByRole("article", { name: "Job 2" })
    expect(article.parentElement?.className).toContain("border-t-4")
  })
})
