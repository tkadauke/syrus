import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter, Route, Routes, useLocation } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "../testSupport"
import { stubVirtualizerMeasurements } from "../test/virtualizerMeasurements"
import { JobTargetGraphPanel, RepositoryTargetGraphRoute, buildGraphRows, targetGraphQueryFromSearch } from "./RepositoryTargetGraph"
import type { TargetGraphPayload, TargetGraphTarget } from "../api/targetGraphs"

stubVirtualizerMeasurements()

function target(label: string, dependencies: string[] = [], overrides: Partial<TargetGraphTarget> = {}): TargetGraphTarget {
  return {
    label,
    kind: "library",
    project_id: "repo",
    dependencies,
    executable: false,
    ...overrides
  }
}

function payload(overrides: Partial<TargetGraphPayload> = {}): TargetGraphPayload {
  return {
    repository: { id: 1, slug: "acme/widgets", default_branch: "main" },
    source: { scope: "repository", ref: "main" },
    tabs: [
      { key: "overview", label: "Overview", path: "/repositories/1" },
      { key: "target_graph", label: "Target Graph", path: "/repositories/1/target_graph" }
    ],
    projects: [{ id: "repo", label: "Repository", target_count: 3 }],
    targets: [
      target("//:app"),
      target("//:assets", [], { kind: "builder", executable: true, executable_metadata: { command: "npm run build" } }),
      target("//:grade/tests", ["//:app", "//:assets"], { kind: "grader", selection: { state: "selected", reason: "changed files matched" } })
    ],
    edges: [
      { from: "//:app", to: "//:grade/tests", kind: "dependency", in_window: true },
      { from: "//:assets", to: "//:grade/tests", kind: "dependency", in_window: true }
    ],
    page: { offset: 0, limit: 180, total: 3, next_offset: null },
    health: { scope: "page", targets: {}, summary: {} },
    diagnostics: { source: ".syrus.yml", target_labels: [] },
    error: null,
    ...overrides
  }
}

function renderRoute(responsePayload: TargetGraphPayload = payload(), initialEntry = "/app-shell/repositories/1/target_graph") {
  const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(() => Promise.resolve(jsonResponse(responsePayload)))
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={[initialEntry]}>
        <Routes>
          <Route element={<RepositoryTargetGraphRoute />} path="/app-shell/repositories/:repositoryId/target_graph" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
  return fetchSpy
}

function LocationProbe() {
  const location = useLocation()
  return <span data-testid="location">{location.pathname}{location.search}</span>
}

describe("RepositoryTargetGraphRoute", () => {
  afterEach(() => vi.restoreAllMocks())

  it("renders a focused graph neighborhood with dependency expansion controls", async () => {
    const fetchSpy = renderRoute()

    expect((await screen.findAllByText("//:grade/tests")).length).toBeGreaterThan(0)
    expect(screen.getByText("npm run build")).toBeInTheDocument()
    expect(screen.getByText("changed files matched")).toBeInTheDocument()
    expect(screen.getAllByRole("button", { name: "//:app" }).length).toBeGreaterThan(0)
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/repositories/1/target_graph?mode=neighborhood&direction=both&depth=1&limit=180",
      expect.any(Object)
    )
  })

  it("keeps large graph rendering bounded to the virtualized window", async () => {
    const targets = Array.from({ length: 1_000 }, (_, index) => target(`//pkg:lib${String(index).padStart(4, "0")}`))
    renderRoute(payload({
      targets,
      edges: [],
      page: { offset: 0, limit: 180, total: 1_000, next_offset: null }
    }))

    expect(await screen.findByText("//pkg:lib0000")).toBeInTheDocument()
    expect(screen.queryByText("//pkg:lib0999")).not.toBeInTheDocument()
    expect(document.querySelectorAll("[data-index]").length).toBeLessThan(80)
  })

  it("updates the URL-backed focus target from the search form", async () => {
    const fetchSpy = renderRoute()

    await screen.findAllByText("//:grade/tests")
    fireEvent.change(screen.getByLabelText("Target label or search"), { target: { value: "//:assets" } })
    fireEvent.click(screen.getByRole("button", { name: "Focus" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenLastCalledWith(
        "/api/v1/app/repositories/1/target_graph?mode=neighborhood&focus_label=%2F%2F%3Aassets&direction=both&depth=1&limit=180",
        expect.any(Object)
      )
    })
  })

  it("disables workflow overlay focus controls for repository graphs", async () => {
    renderRoute()

    await screen.findAllByText("//:grade/tests")
    expect(screen.getByRole("button", { name: "Selected" })).toBeDisabled()
    expect(screen.getByRole("button", { name: "Skipped" })).toBeDisabled()
    expect(screen.getByRole("button", { name: "Cached" })).toBeDisabled()
    expect(screen.getByRole("button", { name: "Failing" })).not.toBeDisabled()
  })

  it("fetches job-scoped graph data so workflow overlay focus controls are available", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(() => Promise.resolve(jsonResponse(payload({
      workflow: { id: 42, slug: "WF-42", job_id: 1, trigger_kind: "initial", state: "running" }
    }))))
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/app-shell/jobs/1?tab=target_graph"]}>
          <JobTargetGraphPanel jobId={1} prefix="/app-shell" />
          <LocationProbe />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("Workflow WF-42")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Selected" })).not.toBeDisabled()
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/jobs/1/target_graph?mode=neighborhood&direction=both&depth=1&limit=180",
      expect.any(Object)
    )

    fireEvent.click(screen.getByRole("button", { name: "Selected" }))

    await waitFor(() => {
      expect(screen.getByTestId("location")).toHaveTextContent("/app-shell/jobs/1?tab=target_graph&focus_state=selected")
      expect(fetchSpy).toHaveBeenLastCalledWith(
        "/api/v1/app/jobs/1/target_graph?mode=neighborhood&focus_state=selected&direction=both&depth=1&limit=180",
        expect.any(Object)
      )
    })
  })
})

describe("target graph route helpers", () => {
  it("parses and clamps progressive graph query parameters", () => {
    expect(targetGraphQueryFromSearch("?mode=window&offset=12&limit=9999&depth=9&direction=dependents")).toMatchObject({
      mode: "window",
      offset: 12,
      limit: 500,
      depth: 4,
      direction: "dependents"
    })
  })

  it("builds dependency and dependent rows from returned edges", () => {
    expect(buildGraphRows(payload().targets, payload().edges)).toEqual([
      expect.objectContaining({ target: expect.objectContaining({ label: "//:app" }), dependents: ["//:grade/tests"] }),
      expect.objectContaining({ target: expect.objectContaining({ label: "//:assets" }), dependents: ["//:grade/tests"] }),
      expect.objectContaining({ target: expect.objectContaining({ label: "//:grade/tests" }), dependencies: ["//:app", "//:assets"] })
    ])
  })
})
