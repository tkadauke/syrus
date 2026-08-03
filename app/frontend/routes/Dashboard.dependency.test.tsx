import { render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { beforeEach, describe, expect, it, vi } from "vitest"
import type { DashboardPayload } from "../api/dashboard"
import * as dashboardApi from "../api/dashboard"
import { DashboardContent, DashboardDependencyView, DashboardToolbar, graphSearchWithSmartFolder } from "./Dashboard"
import * as dashboardComponents from "./dashboard/components"

vi.mock("../api/dashboard", async (importOriginal) => {
  const mod = await importOriginal<typeof import("../api/dashboard")>()
  return { ...mod, fetchJobsGraph: vi.fn(), fetchEpicsGraph: vi.fn(), updateDashboardPreferences: vi.fn() }
})

const mockFetchJobsGraph = vi.mocked(dashboardApi.fetchJobsGraph)
const mockFetchEpicsGraph = vi.mocked(dashboardApi.fetchEpicsGraph)

function buildJobPayload(): DashboardPayload {
  return {
    subject: "job",
    view: "dependencies",
    page: 1,
    per_page: 25,
    total: 0,
    total_pages: 1,
    counts: { jobs: 3, epics: 0, workflows: 0 },
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
      views: ["list", "kanban", "dependencies"],
      ownership_scopes: [],
      owners: [],
      sort_columns: ["title"],
      sort_directions: ["asc", "desc"],
      columns: { required: [], optional: [] },
      kanban_lanes: [],
      filter_schema: [],
      filter_suggestions: []
    },
    landing_queue: { visible: false, paused: false, toggle_path: "", entries: [] },
    ownership: { scope: "team", owner_id: null, team_user_count: 0, badges_visible: false },
    smart_folders: [],
    active_smart_folder_id: null,
    items: [],
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

function buildEpicPayload(): DashboardPayload {
  return { ...buildJobPayload(), subject: "epic", counts: { jobs: 0, epics: 2, workflows: 0 } }
}

function graphNode(id: string, kind: "job" | "epic" = "job", label?: string) {
  return { id, kind, label: label ?? `${id} Label`, state: "open", epic_id: null, url: `/${id}`, is_focal: false }
}

function renderDependencyView(payload: DashboardPayload, graphSearch = "") {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={queryClient}>
      <MemoryRouter>
        <DashboardDependencyView payload={payload} graphSearch={graphSearch} />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("DashboardDependencyView", () => {
  beforeEach(() => {
    mockFetchJobsGraph.mockReset()
    mockFetchEpicsGraph.mockReset()
  })

  it("shows no match message when nodes array is empty", async () => {
    mockFetchJobsGraph.mockResolvedValue({ nodes: [], edges: [] })

    renderDependencyView(buildJobPayload())

    await waitFor(() => {
      expect(screen.getByText("No jobs match this view.")).toBeInTheDocument()
    })
  })

  it("shows no match message for epics subject when nodes are empty", async () => {
    mockFetchEpicsGraph.mockResolvedValue({ nodes: [], edges: [] })

    renderDependencyView(buildEpicPayload())

    await waitFor(() => {
      expect(screen.getByText("No epics match this view.")).toBeInTheDocument()
    })
  })

  it("renders graph nodes with caption hint when nodes exist but edges array is empty", async () => {
    const nodes = [
      graphNode("job_1", "job", "JOB-1 First job"),
      graphNode("job_2", "job", "JOB-2 Second job")
    ]
    mockFetchJobsGraph.mockResolvedValue({ nodes, edges: [] })

    renderDependencyView(buildJobPayload())

    await waitFor(() => {
      expect(screen.getByText("No dependency relationships in the current view.")).toBeInTheDocument()
      expect(screen.getByText("JOB-1")).toBeInTheDocument()
      expect(screen.getByText("JOB-2")).toBeInTheDocument()
    })
    expect(screen.queryByText("No jobs match this view.")).not.toBeInTheDocument()
  })

  it("renders the graph when edges are present for jobs", async () => {
    // JobCompactCard parses "slug title" format — the ID becomes the slug rendered in the card
    const nodes = [
      graphNode("job_1", "job", "JOB-1 First job"),
      graphNode("job_2", "job", "JOB-2 Second job")
    ]
    const edges = [{ from_id: "job_2", to_id: "job_1" }]
    mockFetchJobsGraph.mockResolvedValue({ nodes, edges })

    renderDependencyView(buildJobPayload())

    await waitFor(() => {
      expect(screen.getByText("JOB-1")).toBeInTheDocument()
      expect(screen.getByText("JOB-2")).toBeInTheDocument()
    })
  })

  it("calls fetchEpicsGraph for epic subject", async () => {
    mockFetchEpicsGraph.mockResolvedValue({ nodes: [], edges: [] })

    renderDependencyView(buildEpicPayload())

    await waitFor(() => {
      expect(mockFetchEpicsGraph).toHaveBeenCalled()
      expect(mockFetchJobsGraph).not.toHaveBeenCalled()
    })
  })

  it("calls fetchJobsGraph for job subject", async () => {
    mockFetchJobsGraph.mockResolvedValue({ nodes: [], edges: [] })

    renderDependencyView(buildJobPayload())

    await waitFor(() => {
      expect(mockFetchJobsGraph).toHaveBeenCalled()
      expect(mockFetchEpicsGraph).not.toHaveBeenCalled()
    })
  })

  it("shows load error when fetch fails", async () => {
    mockFetchJobsGraph.mockRejectedValue(new Error("Network error"))

    renderDependencyView(buildJobPayload())

    await waitFor(() => {
      expect(screen.getByText("Unable to load dashboard.")).toBeInTheDocument()
    })
  })

  it("passes graphSearch param to fetch function", async () => {
    mockFetchJobsGraph.mockResolvedValue({ nodes: [], edges: [] })

    renderDependencyView(buildJobPayload(), "?repo=acme%2Fwidgets&state=open")

    await waitFor(() => {
      expect(mockFetchJobsGraph).toHaveBeenCalledWith("?repo=acme%2Fwidgets&state=open", expect.any(Object))
    })
  })

  it("renders nothing for workflow subject", async () => {
    const payload = { ...buildJobPayload(), subject: "workflow" as const, counts: { jobs: 0, epics: 0, workflows: 5 } }

    const { container } = renderDependencyView(payload)

    // workflow subject should render null (no graph, no message)
    await waitFor(() => {
      expect(container.firstChild).toBeNull()
    })
    expect(mockFetchJobsGraph).not.toHaveBeenCalled()
    expect(mockFetchEpicsGraph).not.toHaveBeenCalled()
  })
})

describe("graphSearchWithSmartFolder", () => {
  it("adds smart_folder_id when absent and no q filter", () => {
    expect(graphSearchWithSmartFolder("?subject=job", 5)).toBe("?subject=job&smart_folder_id=5")
  })

  it("does not add smart_folder_id when already present in search", () => {
    expect(graphSearchWithSmartFolder("?smart_folder_id=3&subject=job", 5)).toBe("?smart_folder_id=3&subject=job")
  })

  it("does not add smart_folder_id when q filter is active", () => {
    expect(graphSearchWithSmartFolder("?q=abc123&subject=job", 5)).toBe("?q=abc123&subject=job")
  })

  it("does not add smart_folder_id when activeSfId is null", () => {
    expect(graphSearchWithSmartFolder("?subject=job", null)).toBe("?subject=job")
  })

  it("handles empty raw search and adds smart_folder_id", () => {
    expect(graphSearchWithSmartFolder("", 7)).toBe("?smart_folder_id=7")
  })

  it("returns empty string when search is empty and activeSfId is null", () => {
    expect(graphSearchWithSmartFolder("", null)).toBe("")
  })
})

describe("dashboardChromeSearch", () => {
  it("keeps chrome stable across smart folder and page changes", () => {
    expect(dashboardApi.dashboardChromeSearch("/dashboard/jobs", "?smart_folder_id=8&page=3&view=list&ownership_scope=team")).toBe("?view=list&ownership_scope=team&subject=job")
  })

  it("keeps filter params because they change filter chrome", () => {
    expect(dashboardApi.dashboardChromeSearch("/dashboard/jobs", "?smart_folder_id=8&q=abc123&view=list")).toBe("?q=abc123&view=list&subject=job")
  })
})

function buildToolbarPayload(view: DashboardPayload["view"] = "list"): DashboardPayload {
  return {
    subject: "job",
    view,
    page: 1,
    per_page: 25,
    total: 0,
    total_pages: 1,
    counts: { jobs: 0, epics: 0, workflows: 0 },
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
      views: ["list", "kanban", "dependencies"],
      ownership_scopes: [],
      owners: [],
      sort_columns: ["title"],
      sort_directions: ["asc", "desc"],
      columns: { required: [], optional: [{ key: "owner", title: "Owner" }] },
      kanban_lanes: [{ key: "open", title: "Open" }],
      filter_schema: [],
      filter_suggestions: []
    },
    landing_queue: { visible: false, paused: false, toggle_path: "", entries: [] },
    ownership: { scope: "team", owner_id: null, team_user_count: 0, badges_visible: false },
    smart_folders: [],
    active_smart_folder_id: null,
    items: [],
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

function renderToolbar(payload: DashboardPayload, options: { isDesktop?: boolean } = {}) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={queryClient}>
      <MemoryRouter>
        <DashboardToolbar payload={payload} pathname="/dashboard/jobs" search="" isDesktop={options.isDesktop} />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("DashboardToolbar", () => {
  it("renders column selector before the view tabs nav when in list view", () => {
    const { container } = renderToolbar(buildToolbarPayload("list"))

    const nav = container.querySelector("nav[aria-label]")
    const columnsButton = container.querySelector("button[aria-label='Columns']")

    expect(nav).toBeTruthy()
    expect(columnsButton).toBeTruthy()
    // The columns button should appear before the nav in the DOM
    // eslint-disable-next-line @typescript-eslint/no-non-null-assertion
    expect(columnsButton!.compareDocumentPosition(nav!)).toBe(Node.DOCUMENT_POSITION_FOLLOWING)
  })

  it("renders kanban lanes selector before the view tabs nav when in kanban view", () => {
    const { container } = renderToolbar(buildToolbarPayload("kanban"))

    const nav = container.querySelector("nav[aria-label]")
    const lanesButton = container.querySelector("button[aria-label='Kanban lanes']")

    expect(nav).toBeTruthy()
    expect(lanesButton).toBeTruthy()
    // The kanban lanes button should appear before the nav in the DOM
    // eslint-disable-next-line @typescript-eslint/no-non-null-assertion
    expect(lanesButton!.compareDocumentPosition(nav!)).toBe(Node.DOCUMENT_POSITION_FOLLOWING)
  })

  it("renders only the view tabs nav (no selector) when in dependencies view", () => {
    const { container } = renderToolbar(buildToolbarPayload("dependencies"))

    expect(container.querySelector("nav[aria-label]")).toBeTruthy()
    expect(container.querySelector("button[aria-label='Columns']")).toBeNull()
    expect(container.querySelector("button[aria-label='Kanban lanes']")).toBeNull()
  })

  it("renders dependencies tab on desktop", () => {
    renderToolbar(buildToolbarPayload("list"), { isDesktop: true })

    expect(screen.getByRole("link", { name: "dependencies" })).toBeInTheDocument()
  })

  it("hides dependencies tab on mobile", () => {
    renderToolbar(buildToolbarPayload("list"), { isDesktop: false })

    expect(screen.getByRole("link", { name: "list" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "kanban" })).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "dependencies" })).not.toBeInTheDocument()
  })
})

describe("DashboardContent — dependencies view on mobile", () => {
  it("shows unavailable message instead of graph on mobile", () => {
    vi.spyOn(dashboardComponents, "useMediaQuery").mockReturnValue(false)

    const payload = buildToolbarPayload("dependencies")
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={queryClient}>
        <MemoryRouter>
          <DashboardContent payload={payload} pathname="/dashboard/jobs" prefix="" search="" />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByText("The dependencies view is not available on mobile.")).toBeInTheDocument()
    expect(vi.mocked(dashboardApi.fetchJobsGraph)).not.toHaveBeenCalled()
  })

  it("renders the graph (not the mobile message) on desktop", async () => {
    vi.spyOn(dashboardComponents, "useMediaQuery").mockReturnValue(true)
    vi.mocked(dashboardApi.fetchJobsGraph).mockResolvedValue({ nodes: [], edges: [] })

    const payload = buildToolbarPayload("dependencies")
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={queryClient}>
        <MemoryRouter>
          <DashboardContent payload={payload} pathname="/dashboard/jobs" prefix="" search="" />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.queryByText("The dependencies view is not available on mobile.")).not.toBeInTheDocument()
    await waitFor(() => {
      expect(vi.mocked(dashboardApi.fetchJobsGraph)).toHaveBeenCalled()
    })
  })
})
