import { jsonResponse } from "@app/testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { I18nextProvider } from "react-i18next"
import { MemoryRouter } from "react-router-dom"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import i18n from "@app/i18n"
import { WorkerTimelineRoute } from "./WorkerTimeline"
import type { WorkerTimelineMacroPayload } from "../api/workerTimeline"

function filterSchema() {
  return [
    { field: "repository_id", label: "Repository", bucket: "fk", operators: [ "is" ], typeahead: true },
    { field: "epic_id", label: "Epic", bucket: "fk", operators: [ "is" ], typeahead: true },
    { field: "hostname", label: "Hostname", bucket: "fk", operators: [ "is" ], typeahead: true },
    {
      field: "status",
      label: "Status",
      bucket: "enum",
      operators: [ "is_one_of" ],
      values: [
        { value: "queued", label: "Queued" },
        { value: "running", label: "Running" },
        { value: "succeeded", label: "Succeeded" },
        { value: "failed", label: "Failed" },
        { value: "cancelled", label: "Cancelled" }
      ]
    },
    { field: "window", label: "Time window", bucket: "date", operators: [ "within_last", "between" ] }
  ]
}

function decodeQ(url: string) {
  const q = new URL(url, "http://example.test").searchParams.get("q")
  if (!q) return null

  const normalized = q.replace(/-/g, "+").replace(/_/g, "/")
  const base64 = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=")
  const bytes = Uint8Array.from(atob(base64), (character) => character.charCodeAt(0))
  return JSON.parse(new TextDecoder().decode(bytes))
}

// Adding then selecting a filter value fires two macro requests (the
// just-added chip's default empty value, then the selected value) --
// always assert against the most recent one, not the first "q=" match.
function latestMacroFilter(calls: string[]) {
  const macroCalls = calls.filter((url) => url.startsWith("/api/v1/app/admin/worker_timeline/macro") && url.includes("q="))
  const last = macroCalls.at(-1)
  return last ? decodeQ(last) : null
}

function macroPayload(overrides: Record<string, unknown> = {}) {
  return {
    range: { from: "2026-01-01T00:00:00Z", to: "2026-01-01T01:00:00Z" },
    filter: { and: [] },
    filter_schema: filterSchema(),
    lanes: [
      {
        key: "durable:storage-a:runs",
        worker_storage_key: "storage-a",
        queue_role: "runs",
        hostname: "worker-a",
        pid: 123,
        instance: { id: 1, hostname: "worker-a", started_at: "2026-01-01T00:00:00Z", last_heartbeat_at: "2026-01-01T00:50:00Z", finished_at: null },
        spans: [
          {
            worker_storage_key: "storage-a",
            queue_role: "runs",
            hostname: "worker-a",
            pid: 123,
            workflow_id: 501,
            job_id: 42,
            started_at: "2026-01-01T00:10:00Z",
            finished_at: "2026-01-01T00:20:00Z",
            status: "succeeded",
            label: "JOB-42 · initial",
            job_title: "Fix the aqueducts",
            blocked: { blocked_reason: null, blocked_since: null, blocked_details: {}, next_check_at: null, available: false, historical: true }
          }
        ]
      },
      {
        key: "durable:storage-b:merges",
        worker_storage_key: "storage-b",
        queue_role: "merges",
        hostname: "worker-b",
        pid: 456,
        instance: null,
        spans: [
          {
            worker_storage_key: "storage-b",
            queue_role: "merges",
            hostname: "worker-b",
            pid: 456,
            workflow_id: 502,
            job_id: 43,
            started_at: "2026-01-01T00:15:00Z",
            finished_at: null,
            status: "running",
            label: "JOB-43 · pr_comment",
            job_title: "Investigate flaky CI",
            blocked: { blocked_reason: "provider_availability", blocked_since: "2026-01-01T00:14:00Z", blocked_details: { provider: "codex" }, next_check_at: "2026-01-01T00:16:00Z", available: true, historical: false }
          }
        ]
      }
    ],
    pending: [],
    ...overrides
  }
}

function waterfallPayload(overrides: Record<string, unknown> = {}) {
  return {
    workflow: {
      id: 501,
      job_id: 42,
      trigger_kind: "initial",
      status: "running",
      started_at: "2026-01-01T00:10:00Z",
      finished_at: null,
      worker_storage_key: "storage-a",
      queue_role: "runs",
      hostname: "worker-a",
      pid: 123,
      blocked: { blocked_reason: null, blocked_since: null, blocked_details: {}, next_check_at: null, available: false, historical: false }
    },
    steps: [
      {
        id: 901,
        kind: "prepare",
        status: "succeeded",
        position: 0,
        iteration: 1,
        started_at: "2026-01-01T00:10:00Z",
        finished_at: "2026-01-01T00:12:00Z",
        worker_storage_key: "storage-a",
        queue_role: "runs",
        hostname: "worker-a",
        pid: 123,
        runs: [
          { id: 9001, status: "succeeded", iteration: 1, started_at: "2026-01-01T00:10:00Z", finished_at: "2026-01-01T00:12:00Z", last_heartbeat_at: null }
        ]
      },
      {
        id: 902,
        kind: "implement",
        status: "queued",
        position: 1,
        iteration: 1,
        started_at: null,
        finished_at: null,
        worker_storage_key: "storage-a",
        queue_role: "runs",
        hostname: "worker-a",
        pid: 123,
        runs: [],
        blocked: { blocked_reason: "provider_availability", blocked_since: "2026-01-01T00:09:00Z", blocked_details: { provider: "codex" }, next_check_at: "2026-01-01T00:20:00Z", available: true, historical: false }
      }
    ],
    ...overrides
  }
}

function setupFetchMock(macroOverrides: Record<string, unknown> = {}, waterfallOverrides: Record<string, unknown> = {}) {
  const calls: string[] = []

  vi.spyOn(window, "fetch").mockImplementation(((input: RequestInfo | URL) => {
    const url = String(input)
    calls.push(url)

    if (url.startsWith("/api/v1/app/admin/worker_timeline/macro")) {
      return Promise.resolve(jsonResponse(macroPayload({ filter: decodeQ(url) || { and: [] }, ...macroOverrides })))
    }
    if (url.startsWith("/api/v1/app/admin/worker_timeline/workflow")) {
      return Promise.resolve(jsonResponse(waterfallPayload(waterfallOverrides)))
    }
    if (url.startsWith("/api/v1/app/filters/fk_options")) {
      const field = new URL(url, "http://example.test").searchParams.get("field")
      if (field === "repository_id") return Promise.resolve(jsonResponse({ options: [ { value: 1, label: "acme/widgets" } ] }))
      if (field === "hostname") return Promise.resolve(jsonResponse({ options: [ { value: "worker-b", label: "worker-b" } ] }))
      return Promise.resolve(jsonResponse({ options: [] }))
    }

    return Promise.reject(new Error(`Unexpected fetch: ${url}`))
  }) as typeof window.fetch)

  return calls
}

function renderTimeline(initialPath = "/worker_timeline") {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <I18nextProvider i18n={i18n}>
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={[ initialPath ]}>
          <WorkerTimelineRoute />
        </MemoryRouter>
      </QueryClientProvider>
    </I18nextProvider>
  )
}

describe("WorkerTimeline macro view", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("renders one lane per durable queue role with storage key secondary labels", async () => {
    setupFetchMock()
    renderTimeline()

    expect(await screen.findByText("runs")).toBeInTheDocument()
    expect(screen.getByText("storage-a")).toBeInTheDocument()
    expect(screen.getByText("merges")).toBeInTheDocument()
    expect(screen.getByText("storage-b")).toBeInTheDocument()
    expect(screen.queryByText("worker-a:123")).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "JOB-42 · initial" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "JOB-43 · pr_comment" })).toBeInTheDocument()
  })

  it("shows the empty state when there are no lanes", async () => {
    setupFetchMock({ lanes: [] })
    renderTimeline()

    expect(await screen.findByText("No worker activity in this time range.")).toBeInTheDocument()
  })

  it("uses the shared FilterBar and refetches with the selected repository filter", async () => {
    const calls = setupFetchMock()
    renderTimeline()

    await screen.findByText("runs")

    fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
    fireEvent.click(screen.getByRole("button", { name: "Repository reference" }))
    fireEvent.change(screen.getByPlaceholderText("Search by name..."), { target: { value: "acme" } })
    fireEvent.click(await screen.findByText("acme/widgets"))

    await waitFor(() => {
      expect(latestMacroFilter(calls)).toEqual({ and: [ { field: "repository_id", op: "is", value: "1" } ] })
    })
  })

  it("refetches with the selected status filter", async () => {
    const calls = setupFetchMock()
    renderTimeline()

    await screen.findByText("runs")

    fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
    fireEvent.click(screen.getByRole("button", { name: "Status list" }))
    fireEvent.click(screen.getByRole("button", { name: "Running" }))

    await waitFor(() => {
      expect(latestMacroFilter(calls)).toEqual({ and: [ { field: "status", op: "is_one_of", value: [ "running" ] } ] })
    })
  })

  it("refetches with the selected worker hostname filter", async () => {
    const calls = setupFetchMock()
    renderTimeline()

    await screen.findByText("runs")

    fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
    fireEvent.click(screen.getByRole("button", { name: "Hostname reference" }))
    fireEvent.change(screen.getByPlaceholderText("Search by name..."), { target: { value: "worker-b" } })
    fireEvent.click(await screen.findByText("worker-b"))

    await waitFor(() => {
      expect(latestMacroFilter(calls)).toEqual({ and: [ { field: "hostname", op: "is", value: "worker-b" } ] })
    })
  })

  it("shows no filters and a 3-hour window by default", async () => {
    setupFetchMock()
    renderTimeline()

    await screen.findByText("runs")

    expect(screen.queryByRole("button", { name: /Repository is/ })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /Status is/ })).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "+ Add filter" })).toBeInTheDocument()
  })

  it("shows a tooltip with the job/workflow id, duration, and blocked reason on hover", async () => {
    setupFetchMock()
    renderTimeline()

    const span = await screen.findByRole("button", { name: "JOB-43 · pr_comment" })
    fireEvent.mouseEnter(span)

    const tooltip = await screen.findByRole("tooltip")
    expect(tooltip).toHaveTextContent("JOB-43 · pr_comment")
    expect(tooltip).toHaveTextContent("Investigate flaky CI")
    expect(tooltip).toHaveTextContent("Workflow #502")
    expect(tooltip).toHaveTextContent("ran on host worker-b from 2026-01-01T00:15:00Z–now")
    expect(tooltip).toHaveTextContent("+ (running)")
    expect(tooltip).toHaveTextContent("Blocked: provider_availability")
  })

  it("shows restart dividers when the pid changes within a durable lane", async () => {
    const payload = macroPayload()
    const firstLane = payload.lanes[0] as Record<string, unknown>
    firstLane.spans = [
      {
        worker_storage_key: "storage-a",
        queue_role: "runs",
        hostname: "worker-a",
        pid: 123,
        workflow_id: 501,
        job_id: 42,
        started_at: "2026-01-01T00:10:00Z",
        finished_at: "2026-01-01T00:20:00Z",
        status: "succeeded",
        label: "JOB-42 · initial",
        job_title: "Fix the aqueducts",
        blocked: { blocked_reason: null, blocked_since: null, blocked_details: {}, next_check_at: null, available: false, historical: true }
      },
      {
        worker_storage_key: "storage-a",
        queue_role: "runs",
        hostname: "worker-c",
        pid: 789,
        workflow_id: 503,
        job_id: 44,
        started_at: "2026-01-01T00:25:00Z",
        finished_at: "2026-01-01T00:35:00Z",
        status: "succeeded",
        label: "JOB-44 · retry",
        job_title: "Retry after restart",
        blocked: { blocked_reason: null, blocked_since: null, blocked_details: {}, next_check_at: null, available: false, historical: true }
      }
    ]
    setupFetchMock({ lanes: payload.lanes })
    renderTimeline()

    await screen.findByText("runs")
    const marker = screen.getByRole("img", { name: "worker process restarted here (pid 123 → 789)" })
    fireEvent.mouseEnter(marker)

    expect(await screen.findByRole("tooltip")).toHaveTextContent("worker process restarted here (pid 123 → 789)")
  })

  it("packs genuinely overlapping spans into greedy concurrency sub-rows", async () => {
    const payload = macroPayload({ lanes: [] }) as WorkerTimelineMacroPayload
    payload.lanes = [
      {
        key: "durable:storage-a:runs",
        worker_storage_key: "storage-a",
        queue_role: "runs",
        hostname: "worker-a",
        pid: 123,
        instance: null,
        spans: [
          {
            worker_storage_key: "storage-a",
            queue_role: "runs",
            hostname: "worker-a",
            pid: 123,
            workflow_id: 601,
            job_id: 61,
            started_at: "2026-01-01T00:00:00Z",
            finished_at: "2026-01-01T00:30:00Z",
            status: "running",
            label: "JOB-61 · initial",
            job_title: "",
            blocked: { blocked_reason: null, blocked_since: null, blocked_details: {}, next_check_at: null, available: false, historical: false }
          },
          {
            worker_storage_key: "storage-a",
            queue_role: "runs",
            hostname: "worker-a",
            pid: 123,
            workflow_id: 602,
            job_id: 62,
            started_at: "2026-01-01T00:05:00Z",
            finished_at: "2026-01-01T00:35:00Z",
            status: "running",
            label: "JOB-62 · initial",
            job_title: "",
            blocked: { blocked_reason: null, blocked_since: null, blocked_details: {}, next_check_at: null, available: false, historical: false }
          },
          {
            worker_storage_key: "storage-a",
            queue_role: "runs",
            hostname: "worker-a",
            pid: 123,
            workflow_id: 603,
            job_id: 63,
            started_at: "2026-01-01T00:10:00Z",
            finished_at: "2026-01-01T00:40:00Z",
            status: "running",
            label: "JOB-63 · initial",
            job_title: "",
            blocked: { blocked_reason: null, blocked_since: null, blocked_details: {}, next_check_at: null, available: false, historical: false }
          },
          {
            worker_storage_key: "storage-a",
            queue_role: "runs",
            hostname: "worker-a",
            pid: 123,
            workflow_id: 604,
            job_id: 64,
            started_at: "2026-01-01T00:35:00Z",
            finished_at: "2026-01-01T00:45:00Z",
            status: "succeeded",
            label: "JOB-64 · initial",
            job_title: "",
            blocked: { blocked_reason: null, blocked_since: null, blocked_details: {}, next_check_at: null, available: false, historical: false }
          }
        ]
      }
    ]
    setupFetchMock({ lanes: payload.lanes })
    renderTimeline()

    expect(await screen.findByText("runs")).toBeInTheDocument()
    expect(screen.getByText("2/3")).toBeInTheDocument()
    expect(screen.getByText("3/3")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "JOB-61 · initial" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "JOB-64 · initial" })).toBeInTheDocument()
  })

  it("activates a span with the keyboard, not just a mouse click", async () => {
    setupFetchMock()
    renderTimeline()

    const span = await screen.findByRole("button", { name: "JOB-42 · initial" })
    span.focus()
    fireEvent.keyDown(span, { key: "Enter" })

    expect(await screen.findByText("prepare · iteration 1")).toBeInTheDocument()
  })

  it("plainly says when no historical blocker data is available for a finished span", async () => {
    setupFetchMock()
    renderTimeline()

    const span = await screen.findByRole("button", { name: "JOB-42 · initial" })
    fireEvent.mouseEnter(span)

    const tooltip = await screen.findByRole("tooltip")
    expect(tooltip).toHaveTextContent("Fix the aqueducts")
    expect(tooltip).toHaveTextContent("10m 0s")
    expect(tooltip).toHaveTextContent("No historical blocker data is available for this span.")
  })

  it("navigates to the per-workflow waterfall when a workflow span is clicked", async () => {
    const calls = setupFetchMock()
    renderTimeline()

    const span = await screen.findByRole("button", { name: "JOB-42 · initial" })
    fireEvent.click(span)

    expect(await screen.findByText("prepare · iteration 1")).toBeInTheDocument()
    expect(screen.getByText("implement · iteration 1")).toBeInTheDocument()
    expect(screen.getByText("← Back to Worker Timeline")).toBeInTheDocument()
    expect(calls.some((url) => url.includes("/worker_timeline/workflow") && url.includes("id=501"))).toBe(true)
  })

  it("virtualizes lanes so only the scrolled-into-view rows render, not every lane up front", async () => {
    const lanes = Array.from({ length: 20 }, (_, index) => ({
      key: `durable:storage-${index}:runs`,
      worker_storage_key: `storage-${index}`,
      queue_role: `runs-${index}`,
      hostname: `worker-${index}`,
      pid: 100 + index,
      instance: null,
      spans: [
        {
          worker_storage_key: `storage-${index}`,
          queue_role: `runs-${index}`,
          hostname: `worker-${index}`,
          pid: 100 + index,
          workflow_id: 700 + index,
          job_id: 70 + index,
          started_at: "2026-01-01T00:10:00Z",
          finished_at: "2026-01-01T00:20:00Z",
          status: "succeeded",
          label: `JOB-${70 + index} · initial`,
          job_title: null,
          blocked: { blocked_reason: null, blocked_since: null, blocked_details: {}, next_check_at: null, available: false, historical: true }
        }
      ]
    }))
    setupFetchMock({ lanes })
    renderTimeline()

    expect(await screen.findByText("runs-0")).toBeInTheDocument()
    expect(screen.getByText("runs-13")).toBeInTheDocument()
    expect(screen.queryByText("runs-19")).not.toBeInTheDocument()

    fireEvent.scroll(screen.getByLabelText("Worker lanes"), { target: { scrollTop: 900 } })

    await waitFor(() => {
      expect(screen.getByText("runs-19")).toBeInTheDocument()
    })
    expect(screen.queryByText("runs-0")).not.toBeInTheDocument()
  })
})

describe("WorkerTimeline waterfall (micro) view", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("renders one lane per step with its run spans", async () => {
    setupFetchMock()
    renderTimeline("/worker_timeline/workflow?id=501")

    expect(await screen.findByText("prepare · iteration 1")).toBeInTheDocument()
    expect(screen.getByText("implement · iteration 1")).toBeInTheDocument()
    expect(screen.getByRole("img", { name: "Run #9001 · succeeded" })).toBeInTheDocument()
  })

  it("shows a 'not started' marker for a step with no started run, not a bar", async () => {
    setupFetchMock()
    renderTimeline("/worker_timeline/workflow?id=501")

    await screen.findByText("prepare · iteration 1")
    expect(screen.getByRole("button", { name: "Not started" })).toBeInTheDocument()
  })

  it("reuses the workflow's blocked-reason explanation as the tooltip for a not-yet-started step", async () => {
    setupFetchMock()
    renderTimeline("/worker_timeline/workflow?id=501")

    const marker = await screen.findByRole("button", { name: "Not started" })
    fireEvent.mouseEnter(marker)

    const tooltip = await screen.findByRole("tooltip")
    expect(tooltip).toHaveTextContent("implement · iteration 1")
    expect(tooltip).toHaveTextContent("Blocked: provider_availability")
  })

  it("shows a run tooltip with id, status, and duration on hover", async () => {
    setupFetchMock()
    renderTimeline("/worker_timeline/workflow?id=501")

    const run = await screen.findByRole("img", { name: "Run #9001 · succeeded" })
    fireEvent.mouseEnter(run)

    const tooltip = await screen.findByRole("tooltip")
    expect(tooltip).toHaveTextContent("Run #9001")
    expect(tooltip).toHaveTextContent("succeeded")
    expect(tooltip).toHaveTextContent("2m 0s")
  })

  it("skips the time axis and shows every step as not-started when the workflow itself hasn't started", async () => {
    setupFetchMock({}, {
      workflow: {
        id: 501, job_id: 42, trigger_kind: "initial", status: "queued", started_at: null, finished_at: null, worker_storage_key: null, queue_role: null, hostname: null, pid: null,
        blocked: { blocked_reason: "provider_availability", blocked_since: null, blocked_details: {}, next_check_at: null, available: true, historical: false }
      },
      steps: [
        { id: 901, kind: "prepare", status: "queued", position: 0, iteration: 1, started_at: null, finished_at: null, worker_storage_key: null, queue_role: null, hostname: null, pid: null, runs: [],
          blocked: { blocked_reason: "provider_availability", blocked_since: null, blocked_details: {}, next_check_at: null, available: true, historical: false } }
      ]
    })
    renderTimeline("/worker_timeline/workflow?id=501")

    expect(await screen.findByText("This workflow hasn't started running yet. Hover a step below to see why.")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Not started" })).toBeInTheDocument()
  })

  it("shows a message when no workflow id is present in the URL", async () => {
    setupFetchMock()
    renderTimeline("/worker_timeline/workflow")

    expect(await screen.findByText("No workflow selected.")).toBeInTheDocument()
  })
})
