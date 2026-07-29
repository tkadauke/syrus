import { render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { beforeEach, describe, expect, it, vi } from "vitest"
import type { DashboardPayload } from "../api/dashboard"
import * as dashboardApi from "../api/dashboard"
import { DashboardDependencyView } from "./Dashboard"

vi.mock("../api/dashboard", async (importOriginal) => {
  const mod = await importOriginal<typeof import("../api/dashboard")>()
  return { ...mod, fetchJobsGraph: vi.fn(), fetchEpicsGraph: vi.fn() }
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

  it("shows 'no dependency edges' message when edges array is empty for jobs", async () => {
    mockFetchJobsGraph.mockResolvedValue({ nodes: [graphNode("job_1"), graphNode("job_2")], edges: [] })

    renderDependencyView(buildJobPayload())

    await waitFor(() => {
      expect(screen.getByText("No dependency relationships in the current view.")).toBeInTheDocument()
    })
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
