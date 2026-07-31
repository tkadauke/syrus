import { render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { DashboardJobItem, DashboardPayload } from "../api/dashboard"
import { DashboardTable } from "./Dashboard"
import { PRIORITY_TONE } from "./dashboard/JobsTable"

// Only `id`, `priority`, `type`, `epic`, and `landing_queue_entry_key` are
// read by the priority cell path.
function jobItem(id: number, priority: string): DashboardJobItem {
  return { id, priority, type: "job", epic: null, landing_queue_entry_key: null } as unknown as DashboardJobItem
}

// Richer fixture for Kanban cards, which access title, repository, paths, etc.
function kanbanJobItem(id: number, priority: string): DashboardJobItem {
  return {
    id,
    priority,
    type: "job",
    epic: null,
    landing_queue_entry_key: null,
    title: `Job ${id}`,
    title_pending: false,
    needs_attention: false,
    owner_badge: null,
    pr_number: null,
    pr_url: null,
    summary_state: "running",
    active_workflow_trigger_kind: null,
    repository: { id: 1, slug: "owner/repo", repository_path: "/repos/1" },
    paths: { job_path: `/jobs/${id}`, source_path: `/jobs/${id}` },
  } as unknown as DashboardJobItem
}

function mobileJobItem(id: number, priority: string): DashboardJobItem {
  return {
    ...kanbanJobItem(id, priority),
    approved_at: "2026-07-31T12:00:00Z",
    created_at: "2026-07-31T12:00:00Z",
    started_at: "2026-07-31T12:00:00Z",
    kind: "direct",
    source_chat: null,
    state: "running",
    summary_state: "succeeded",
    tags: [],
    total_cost_usd: null,
    workflows_count: 1,
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

function renderPayload(payload: DashboardPayload) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={queryClient}>
      <MemoryRouter>
        <DashboardTable payload={payload} prefix="" setupStatus={null} />
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

describe("PRIORITY_TONE", () => {
  it("maps urgent to red", () => {
    expect(PRIORITY_TONE["urgent"]).toBe("red")
  })

  it("maps high to amber", () => {
    expect(PRIORITY_TONE["high"]).toBe("amber")
  })

  it("maps low to blue", () => {
    expect(PRIORITY_TONE["low"]).toBe("blue")
  })

  it("has no entry for medium (empty cell for medium)", () => {
    expect(PRIORITY_TONE["medium"]).toBeUndefined()
  })
})

describe("urgent row highlight", () => {
  it("applies a red background to the desktop table row for urgent jobs", () => {
    renderTable([ jobItem(1, "urgent") ])
    const pill = screen.getByText("urgent")
    const row = pill.closest("tr")
    expect(row?.className).toContain("bg-red-50")
  })

  it("does not apply a red background to high-priority rows", () => {
    renderTable([ jobItem(2, "high") ])
    const pill = screen.getByText("high")
    const row = pill.closest("tr")
    expect(row?.className ?? "").not.toContain("bg-red-50")
  })

  it("does not apply a red background to medium-priority rows", () => {
    const { container } = renderTable([ jobItem(3, "medium") ])
    const tbody = container.querySelector("tbody")
    const row = tbody?.querySelector("tr")
    expect(row?.className ?? "").not.toContain("bg-red-50")
  })

  it("renders the mobile jobs list edge-to-edge without a boxed card margin", () => {
    mockMediaQuery(false)
    renderTable([ mobileJobItem(3, "medium") ])

    const row = screen.getByRole("article", { name: "Job 3" })
    const list = row.parentElement?.parentElement

    expect(list?.className).toContain("border-y")
    expect(list?.className).toContain("sm:rounded")
    expect(list?.className).toContain("sm:border")
    expect(list?.className).not.toContain("rounded border")
  })
})

describe("urgent kanban card highlight", () => {
  function kanbanPayload(item: DashboardJobItem): DashboardPayload {
    return { ...buildPayload([item]), view: "kanban", lanes: [{ key: "running", title: "Running", count: 1, items: [item] }] }
  }

  it("applies a red background to the kanban card for urgent jobs", () => {
    const { container } = renderPayload(kanbanPayload(kanbanJobItem(1, "urgent")))
    const article = container.querySelector("article")
    expect(article?.className).toContain("bg-red-50")
  })

  it("does not apply a red background to the kanban card for high-priority jobs", () => {
    const { container } = renderPayload(kanbanPayload(kanbanJobItem(2, "high")))
    const article = container.querySelector("article")
    expect(article?.className ?? "").not.toContain("bg-red-50")
  })
})

describe("priority column rendering", () => {
  it("renders a red pill for urgent jobs", () => {
    renderTable([ jobItem(1, "urgent") ])
    const pill = screen.getByText("urgent")
    expect(pill.closest("[data-status-pill]")).not.toBeNull()
    expect(pill.closest("[data-status-pill]")?.className).toContain("red")
  })

  it("renders an amber pill for high-priority jobs", () => {
    renderTable([ jobItem(2, "high") ])
    const pill = screen.getByText("high")
    expect(pill.closest("[data-status-pill]")).not.toBeNull()
    expect(pill.closest("[data-status-pill]")?.className).toContain("amber")
  })

  it("renders a blue pill for low-priority jobs", () => {
    renderTable([ jobItem(3, "low") ])
    const pill = screen.getByText("low")
    expect(pill.closest("[data-status-pill]")).not.toBeNull()
    expect(pill.closest("[data-status-pill]")?.className).toContain("blue")
  })

  it("renders no pill for medium-priority jobs", () => {
    renderTable([ jobItem(4, "medium") ])
    expect(screen.queryByText("medium")).toBeNull()
  })
})
