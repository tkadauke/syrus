import { jsonResponse } from "../../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { RepositoryTestsRoute } from "./RepositoryTests"
import type { RepositoryTestDetailPayload, RepositoryTestsPayload } from "../../api/repositories"

const REPOSITORY = { id: 1, slug: "acme/widgets", github_url: "https://github.com/acme/widgets" }
const TABS = [ { key: "tests", label: "Tests", path: "/repositories/1?tab=tests" } ]

function listPayload(): RepositoryTestsPayload {
  return {
    repository: REPOSITORY,
    tabs: [],
    query: "",
    limit: 20,
    tests: []
  }
}

function detailPayload(): RepositoryTestDetailPayload {
  const test = {
    id: 42,
    suite_name: "spec/models/job_spec.rb",
    name: "does the thing",
    file_path: "spec/models/job_spec.rb",
    fingerprint: "abc123def456",
    last_status: "failed" as const,
    last_seen_at: "2026-08-19T12:00:00Z",
    last_failed_at: "2026-08-19T12:00:00Z",
    last_passed_at: "2026-08-18T12:00:00Z",
    last_duration_ms: 900,
    total_count: 4,
    failed_count: 1,
    passed_count: 2,
    failure_rate: 0.25,
    avg_duration_ms: 637,
    interesting_reasons: [ "failing" ]
  }

  const history = [
    { id: 101, status: "passed" as const, duration_ms: 600, failure_message: null, created_at: "2026-08-16T10:00:00Z", grader_name: "rspec", run: { id: 501, slug: "RUN-501", path: "/jobs/55?tab=workflows#run-501" }, job: { id: 55, slug: "JOB-55", title: "Fix thing" } },
    { id: 102, status: "skipped" as const, duration_ms: 400, failure_message: null, created_at: "2026-08-17T10:00:00Z", grader_name: "rspec", run: { id: 502, slug: "RUN-502", path: "/jobs/56?tab=workflows#run-502" }, job: { id: 56, slug: "JOB-56", title: "Another thing" } },
    { id: 103, status: "failed" as const, duration_ms: 900, failure_message: "expected true to be false", created_at: "2026-08-18T10:00:00Z", grader_name: "rspec", run: { id: 503, slug: "RUN-503", path: "/jobs/57?tab=workflows#run-503" }, job: { id: 57, slug: "JOB-57", title: "Break thing" } },
    { id: 104, status: "passed" as const, duration_ms: 650, failure_message: null, created_at: "2026-08-19T10:00:00Z", grader_name: "rspec", run: { id: 504, slug: "RUN-504", path: "/jobs/58?tab=workflows#run-504" }, job: { id: 58, slug: "JOB-58", title: "Fix again" } }
  ]

  return {
    repository: REPOSITORY,
    tabs: [],
    test,
    history,
    pagination: { page: 1, per_page: history.length, total: history.length, total_pages: 1 },
    duration_points: history.map((item) => ({ test_case_id: item.id, created_at: item.created_at, duration_ms: item.duration_ms as number, status: item.status }))
  }
}

function mockFetch() {
  vi.spyOn(window, "fetch").mockImplementation((input) => {
    const url = typeof input === "string" ? input : input.toString()
    if (url.includes("/tests/42")) return Promise.resolve(jsonResponse(detailPayload()))
    if (url.includes("/tests")) return Promise.resolve(jsonResponse(listPayload()))
    return Promise.reject(new Error(`unexpected fetch: ${url}`))
  })
}

function buildTestsPayload(): RepositoryTestsPayload {
  return { repository: REPOSITORY, tabs: TABS, query: "", limit: 10, tests: [] }
}

function buildDetailPayload(page: number): RepositoryTestDetailPayload {
  const test = {
    id: 42,
    suite_name: "Suite",
    name: "tracks history",
    file_path: null,
    fingerprint: "abcdef0123456789",
    last_status: "passed" as const,
    last_seen_at: null,
    last_failed_at: null,
    last_passed_at: null,
    last_duration_ms: null,
    total_count: 2,
    failed_count: 1,
    passed_count: 1,
    failure_rate: 0.5,
    avg_duration_ms: 175,
    interesting_reasons: []
  }

  const history = page === 1
    ? [ { id: 2, status: "passed" as const, duration_ms: 100, failure_message: null, created_at: "2026-01-02T00:00:00Z", grader_name: "rspec", run: { id: 10, slug: "RUN-10", path: "/jobs/1" }, job: { id: 1, slug: "JOB-1", title: "t" } } ]
    : [ { id: 1, status: "failed" as const, duration_ms: 250, failure_message: "boom", created_at: "2026-01-01T00:00:00Z", grader_name: "rspec", run: { id: 9, slug: "RUN-9", path: "/jobs/1" }, job: { id: 1, slug: "JOB-1", title: "t" } } ]

  return {
    repository: REPOSITORY,
    tabs: TABS,
    test,
    history,
    pagination: { page, per_page: 1, total: 2, total_pages: 2 },
    duration_points: []
  }
}

function renderRoute() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={[ "/tests-panel" ]}>
        <Routes>
          <Route element={<RepositoryTestsRoute prefix="" repositoryId="1" selectedTestId="42" />} path="/tests-panel" />
          <Route element={<div>Run detail page</div>} path="/jobs/:id" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("DurationChart", () => {
  afterEach(() => vi.restoreAllMocks())

  it("renders a y-axis with more than one distinct tick value", async () => {
    mockFetch()
    const { container } = renderRoute()

    await screen.findByText("Duration over time")

    const tickValues = new Set(Array.from(container.querySelectorAll("svg text")).map((node) => node.textContent))
    expect(tickValues.size).toBeGreaterThan(1)
  })

  it("colors dots by status: green for passed, yellow for skipped, red for failed", async () => {
    mockFetch()
    const { container } = renderRoute()

    await screen.findByText("Duration over time")

    expect(container.querySelectorAll("circle.fill-green-500").length).toBeGreaterThan(0)
    expect(container.querySelectorAll("circle.fill-yellow-500").length).toBeGreaterThan(0)
    expect(container.querySelectorAll("circle.fill-red-500").length).toBeGreaterThan(0)
  })

  it("shows a hover tooltip with status, exact duration, and run context", async () => {
    mockFetch()
    renderRoute()

    await screen.findByText("Duration over time")

    const failedDot = screen.getByRole("button", { name: /Failed, 900ms/ })
    fireEvent.mouseEnter(failedDot)

    const tooltip = within(screen.getByTestId("duration-tooltip"))
    expect(tooltip.getByText("900ms")).toBeInTheDocument()
    expect(tooltip.getByText("expected true to be false")).toBeInTheDocument()
    expect(tooltip.getByText(/JOB-57/)).toBeInTheDocument()
    expect(tooltip.getByText(/Click to open RUN-503/)).toBeInTheDocument()
  })

  it("navigates to the run when a dot is clicked", async () => {
    mockFetch()
    renderRoute()

    await screen.findByText("Duration over time")

    const failedDot = screen.getByRole("button", { name: /Failed, 900ms/ })
    fireEvent.click(failedDot)

    expect(await screen.findByText("Run detail page")).toBeInTheDocument()
  })
})

describe("RepositoryTestsRoute history pagination", () => {
  afterEach(() => vi.restoreAllMocks())

  it("renders the newest history page first and fetches the next page on demand", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const url = typeof input === "string" ? input : input.toString()
      if (url.includes("/tests/42")) {
        const page = url.includes("page=2") ? 2 : 1
        return Promise.resolve(jsonResponse(buildDetailPayload(page)))
      }
      return Promise.resolve(jsonResponse(buildTestsPayload()))
    })

    renderRoute()

    await screen.findByText("RUN-10")
    expect(screen.queryByText("RUN-9")).not.toBeInTheDocument()

    fireEvent.click(await screen.findByRole("button", { name: "Next" }))

    await screen.findByText("RUN-9")
    expect(screen.queryByText("RUN-10")).not.toBeInTheDocument()

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(expect.stringContaining("/tests/42?page=2"), expect.anything())
    })
  })
})
