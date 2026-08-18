import { render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { DashboardJobItem, DashboardPayload } from "../api/dashboard"
import { DashboardTable } from "./Dashboard"

// Covers the mobile jobs list row shape requested in the "Dashboard Jobs
// detail on mobile" issue: no workflow count, no duplicated approval text,
// the job kind sits on the same metadata line as the job slug, and the
// timestamp reflects the latest workflow's start rather than the job's own
// started_at/created_at.

function mobileJobItem(overrides: Partial<DashboardJobItem> = {}): DashboardJobItem {
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
    latest_workflow_started_at: "2026-07-31T11:30:00Z",
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
        required: [{ key: "priority", title: "Priority" }],
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

const originalMatchMedia = Object.getOwnPropertyDescriptor(window, "matchMedia")

afterEach(() => {
  vi.restoreAllMocks()
  if (originalMatchMedia) {
    Object.defineProperty(window, "matchMedia", originalMatchMedia)
  } else {
    Reflect.deleteProperty(window, "matchMedia")
  }
})

function mockMobileViewport() {
  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    writable: true,
    value: vi.fn((query: string) => ({
      matches: false,
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

describe("mobile jobs list row", () => {
  it("does not render the workflow count", () => {
    mockMobileViewport()
    renderTable([ mobileJobItem() ])

    expect(screen.queryByText(/workflow/i)).not.toBeInTheDocument()
  })

  it("does not render a redundant approval label for an approved job", () => {
    mockMobileViewport()
    renderTable([ mobileJobItem({ approved_at: "2026-07-31T12:00:00Z" }) ])

    expect(screen.queryByText("Approved")).not.toBeInTheDocument()
  })

  it("does not render a not-approved label", () => {
    mockMobileViewport()
    renderTable([ mobileJobItem({ approved_at: null }) ])

    expect(screen.queryByText("Not approved")).not.toBeInTheDocument()
  })

  it("renders the job kind on the same metadata line as the job slug", () => {
    mockMobileViewport()
    renderTable([ mobileJobItem({ kind: "direct" }) ])

    const slug = screen.getByText("JOB-3")
    const kindLabel = screen.getByText("Direct")
    const metadataLine = slug.closest("div")

    expect(metadataLine).not.toBeNull()
    expect(metadataLine?.contains(kindLabel)).toBe(true)
  })

  it("uses the latest workflow's start time instead of the job's own started_at", () => {
    mockMobileViewport()
    renderTable([ mobileJobItem({
      started_at: "2026-07-31T11:00:00Z",
      created_at: "2026-07-31T10:00:00Z",
      latest_workflow_started_at: "2026-07-31T11:30:00Z"
    }) ])

    const time = screen.getByRole("article", { name: "Job 3" }).querySelector("time")
    expect(time?.getAttribute("dateTime")).toBe("2026-07-31T11:30:00Z")
  })

  it("falls back to the job's started_at when there is no latest workflow start yet", () => {
    mockMobileViewport()
    renderTable([ mobileJobItem({
      started_at: "2026-07-31T11:00:00Z",
      created_at: "2026-07-31T10:00:00Z",
      latest_workflow_started_at: null
    }) ])

    const time = screen.getByRole("article", { name: "Job 3" }).querySelector("time")
    expect(time?.getAttribute("dateTime")).toBe("2026-07-31T11:00:00Z")
  })
})
