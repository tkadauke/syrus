import { jsonResponse } from "@app/testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { RepositoryTestsRoute } from "./RepositoryTests"
import type { RepositoryTestDetailPayload, RepositoryTestsPayload } from "../api/tests"

const REPOSITORY = { id: 1, slug: "acme/widgets", github_url: "https://github.com/acme/widgets" }
const TABS = [ { key: "test_insights.tests", label: "Tests", path: "/repositories/1?tab=tests" } ]

const FILTER_SCHEMA = [
  { field: "query", label: "Search", bucket: "string", operators: [ "contains" ], values: [], free_text_search: true },
  {
    field: "reason",
    label: "Reason",
    bucket: "enum",
    operators: [ "is" ],
    values: [
      { value: "failing", label: "Failing" },
      { value: "flaky", label: "Flaky" },
      { value: "slow", label: "Slow" }
    ]
  },
  {
    field: "status",
    label: "Status",
    bucket: "enum",
    operators: [ "is" ],
    values: [
      { value: "passed", label: "Passed" },
      { value: "failed", label: "Failed" },
      { value: "error", label: "Error" },
      { value: "skipped", label: "Skipped" }
    ]
  },
  {
    field: "suite_name",
    label: "Suite",
    bucket: "string",
    operators: [ "contains" ],
    values: []
  },
  {
    field: "file_path",
    label: "File path",
    bucket: "string",
    operators: [ "contains" ],
    values: []
  }
]

function listPayload(): RepositoryTestsPayload {
  return {
    repository: REPOSITORY,
    tabs: [],
    filter: { and: [] },
    filter_schema: FILTER_SCHEMA,
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
  return { repository: REPOSITORY, tabs: TABS, filter: { and: [] }, filter_schema: FILTER_SCHEMA, tests: [] }
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

describe("RepositoryTestsRoute tab bar", () => {
  afterEach(() => vi.restoreAllMocks())

  it("highlights the Tests tab using the real repo_page_tab id, not a mismatched literal", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(buildTestsPayload()))

    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={[ "/tests-panel" ]}>
          <Routes>
            <Route element={<RepositoryTestsRoute prefix="" repositoryId="1" selectedTestId={null} />} path="/tests-panel" />
          </Routes>
        </MemoryRouter>
      </QueryClientProvider>
    )

    const testsLink = await screen.findByRole("link", { name: "Tests" })
    expect(testsLink.className).toContain("border-brand")
  })
})

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

const COLUMNS_STORAGE_KEY = "syrus.test_insights.repository_tests_columns"

const ALL_TESTS: RepositoryTestsPayload["tests"] = [
  { id: 1, suite_name: "spec/a_spec.rb", name: "Zebra test", file_path: "spec/a_spec.rb", fingerprint: "f1", last_status: "passed", last_seen_at: "2026-01-03T00:00:00Z", last_failed_at: null, last_passed_at: "2026-01-03T00:00:00Z", last_duration_ms: 100, total_count: 5, failed_count: 0, passed_count: 5, failure_rate: 0, avg_duration_ms: 100, interesting_reasons: [] },
  { id: 2, suite_name: "spec/b_spec.rb", name: "Alpha test", file_path: "spec/b_spec.rb", fingerprint: "f2", last_status: "failed", last_seen_at: "2026-01-01T00:00:00Z", last_failed_at: "2026-01-01T00:00:00Z", last_passed_at: null, last_duration_ms: 500, total_count: 4, failed_count: 3, passed_count: 1, failure_rate: 0.75, avg_duration_ms: 500, interesting_reasons: [ "failing" ] },
  { id: 3, suite_name: "spec/c_spec.rb", name: "Middle test", file_path: "spec/c_spec.rb", fingerprint: "f3", last_status: "passed", last_seen_at: "2026-01-02T00:00:00Z", last_failed_at: "2026-01-01T00:00:00Z", last_passed_at: "2026-01-02T00:00:00Z", last_duration_ms: 2000, total_count: 4, failed_count: 1, passed_count: 3, failure_rate: 0.25, avg_duration_ms: 2000, interesting_reasons: [ "flaky", "slow" ] }
]

function multiTestPayload(): RepositoryTestsPayload {
  return { repository: REPOSITORY, tabs: TABS, filter: { and: [] }, filter_schema: FILTER_SCHEMA, tests: ALL_TESTS }
}

function decodeFilterTree(q: string): { and?: Array<{ field: string; op: string; value?: unknown }> } {
  const normalized = q.replace(/-/g, "+").replace(/_/g, "/")
  const base64 = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=")
  const bytes = Uint8Array.from(atob(base64), (character) => character.charCodeAt(0))
  return JSON.parse(new TextDecoder().decode(bytes))
}

function encoded(tree: unknown) {
  const bytes = new TextEncoder().encode(JSON.stringify(tree))
  let binary = ""
  bytes.forEach((byte) => { binary += String.fromCharCode(byte) })
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

function dataTransfer() {
  return { dropEffect: "", effectAllowed: "", getData: vi.fn(), setData: vi.fn() }
}

// Stands in for the server: reads the FilterBar's `q=` param off the request
// URL and filters ALL_TESTS by `reason` the same way the real backend does,
// so clicking through the FilterBar exercises the same refetch-on-filter
// path the real page uses.
function renderTestList(initialEntry = "/tests-panel") {
  vi.spyOn(window, "fetch").mockImplementation((input) => {
    const url = new URL(String(input), "http://test.host")
    const q = url.searchParams.get("q")
    const tree = q ? decodeFilterTree(q) : { and: [] }
    const chips = tree.and ?? []
    const tests = ALL_TESTS.filter((test) => {
      const reason = chips.find((chip) => chip.field === "reason")?.value
      const status = chips.find((chip) => chip.field === "status")?.value
      const suite = chips.find((chip) => chip.field === "suite_name")?.value
      const filePath = chips.find((chip) => chip.field === "file_path")?.value

      if (typeof reason === "string" && !test.interesting_reasons.includes(reason)) return false
      if (typeof status === "string" && test.last_status !== status) return false
      if (typeof suite === "string" && !test.suite_name.includes(suite)) return false
      if (typeof filePath === "string" && !test.file_path?.includes(filePath)) return false
      return true
    })

    return Promise.resolve(jsonResponse({ repository: REPOSITORY, tabs: TABS, filter: tree, filter_schema: FILTER_SCHEMA, tests }))
  })
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={[ initialEntry ]}>
        <Routes>
          <Route element={<RepositoryTestsRoute prefix="" repositoryId="1" selectedTestId={null} />} path="/tests-panel" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function visibleTestOrder() {
  return screen.getAllByRole("link")
    .map((link) => link.textContent)
    .filter((text): text is string => text === "Zebra test" || text === "Alpha test" || text === "Middle test")
}

describe("RepositoryTestsRoute test list", () => {
  afterEach(() => {
    vi.restoreAllMocks()
    window.localStorage.clear()
  })

  it("sorts the test list ascending then descending when the Test header is clicked", async () => {
    renderTestList()
    await screen.findByText("Zebra test")

    expect(visibleTestOrder()).toEqual([ "Zebra test", "Alpha test", "Middle test" ])

    fireEvent.click(screen.getByRole("button", { name: "Test" }))
    await waitFor(() => expect(visibleTestOrder()).toEqual([ "Alpha test", "Middle test", "Zebra test" ]))

    fireEvent.click(screen.getByRole("button", { name: "Test" }))
    await waitFor(() => expect(visibleTestOrder()).toEqual([ "Zebra test", "Middle test", "Alpha test" ]))
  })

  it("filters the test list through the FilterBar's reason field", async () => {
    renderTestList()
    await screen.findByText("Zebra test")

    fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
    fireEvent.click(screen.getByRole("button", { name: "Reason list" }))

    await waitFor(() => expect(visibleTestOrder()).toEqual([ "Alpha test" ]))
    expect(screen.getByRole("button", { name: "Reason is Failing" })).toBeInTheDocument()

    fireEvent.click(screen.getByRole("link", { name: "Clear filters" }))
    await waitFor(() => expect(visibleTestOrder()).toHaveLength(3))
  })

  it("filters the test list through status and suite chips", async () => {
    const tree = { and: [
      { field: "status", op: "is", value: "passed" },
      { field: "suite_name", op: "contains", value: "spec/c" }
    ] }
    renderTestList(`/tests-panel?q=${encoded(tree)}`)

    await waitFor(() => expect(visibleTestOrder()).toEqual([ "Middle test" ]))
    expect(screen.getByRole("button", { name: "Status is Passed" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Suite contains spec/c" })).toBeInTheDocument()
  })

  it("hides a column from the Columns menu and persists the choice", async () => {
    renderTestList()
    await screen.findByText("Zebra test")

    expect(screen.getByRole("columnheader", { name: "Suite" })).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Columns" }))
    fireEvent.click(screen.getByRole("checkbox", { name: "Suite" }))

    expect(screen.queryByRole("columnheader", { name: "Suite" })).not.toBeInTheDocument()

    const stored = JSON.parse(window.localStorage.getItem(COLUMNS_STORAGE_KEY) || "{}")
    expect(stored).not.toContain("suite")
  })

  it("reorders columns by dragging a row in the Columns menu and persists the order", async () => {
    renderTestList()
    await screen.findByText("Zebra test")

    fireEvent.click(screen.getByRole("button", { name: "Columns" }))

    const suiteRow = screen.getByRole("checkbox", { name: "Suite" }).closest("[draggable]") as HTMLElement
    const lastSeenRow = screen.getByRole("checkbox", { name: "Last seen" }).closest("[draggable]") as HTMLElement

    const transfer = dataTransfer()
    fireEvent.dragStart(suiteRow, { dataTransfer: transfer })
    fireEvent.dragOver(lastSeenRow, { dataTransfer: transfer })
    fireEvent.drop(lastSeenRow, { dataTransfer: transfer })
    fireEvent.dragEnd(suiteRow, { dataTransfer: transfer })

    const stored = JSON.parse(window.localStorage.getItem(COLUMNS_STORAGE_KEY) || "[]")
    expect(stored.indexOf("suite")).toBeGreaterThan(stored.indexOf("last_seen"))
  })

  it("reorders columns by dragging a table header and persists the order", async () => {
    renderTestList()
    await screen.findByText("Zebra test")

    const suiteHeader = screen.getByRole("columnheader", { name: /Suite/ })
    const lastSeenHeader = screen.getByRole("columnheader", { name: /Last seen/ })
    const transfer = dataTransfer()

    fireEvent.dragStart(suiteHeader, { dataTransfer: transfer })
    fireEvent.dragOver(lastSeenHeader, { dataTransfer: transfer })
    fireEvent.drop(lastSeenHeader, { dataTransfer: transfer })
    fireEvent.dragEnd(suiteHeader, { dataTransfer: transfer })

    const headers = screen.getAllByRole("columnheader").map((cell) => cell.textContent)
    expect(headers).toEqual([ "Test", "Recent failures", "Duration", "Last seen", "Suite" ])

    const stored = JSON.parse(window.localStorage.getItem(COLUMNS_STORAGE_KEY) || "[]")
    expect(stored.indexOf("suite")).toBeGreaterThan(stored.indexOf("last_seen"))
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
