import { jsonResponse } from "@app/testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { I18nextProvider } from "react-i18next"
import { MemoryRouter } from "react-router-dom"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import i18n from "@app/i18n"
import { WorkerTimelineRoute } from "./WorkerTimeline"

function filtersPayload() {
  return {
    repositories: [ { id: 1, slug: "acme/widgets" } ],
    epics: [ { id: 9, display_number: "EPIC-9", title: "Worker activity timeline" } ],
    statuses: [ "queued", "running", "succeeded", "failed", "cancelled" ],
    hostnames: [ "worker-a", "worker-b" ]
  }
}

function macroPayload(overrides: Record<string, unknown> = {}) {
  return {
    range: { from: "2026-01-01T00:00:00Z", to: "2026-01-01T01:00:00Z" },
    lanes: [
      {
        hostname: "worker-a",
        pid: 123,
        instance: { id: 1, hostname: "worker-a", started_at: "2026-01-01T00:00:00Z", last_heartbeat_at: "2026-01-01T00:50:00Z", finished_at: null },
        spans: [
          {
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
        hostname: "worker-b",
        pid: 456,
        instance: null,
        spans: [
          {
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

    if (url.startsWith("/api/v1/app/admin/worker_timeline/filters")) {
      return Promise.resolve(jsonResponse(filtersPayload()))
    }
    if (url.startsWith("/api/v1/app/admin/worker_timeline/macro")) {
      return Promise.resolve(jsonResponse(macroPayload(macroOverrides)))
    }
    if (url.startsWith("/api/v1/app/admin/worker_timeline/workflow")) {
      return Promise.resolve(jsonResponse(waterfallPayload(waterfallOverrides)))
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

  it("renders one lane per hostname+pid with its spans", async () => {
    setupFetchMock()
    renderTimeline()

    expect(await screen.findByText("worker-a:123")).toBeInTheDocument()
    expect(await screen.findByText("worker-b:456")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "JOB-42 · initial" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "JOB-43 · pr_comment" })).toBeInTheDocument()
  })

  it("shows the empty state when there are no lanes", async () => {
    setupFetchMock({ lanes: [] })
    renderTimeline()

    expect(await screen.findByText("No worker activity in this time range.")).toBeInTheDocument()
  })

  it("refetches with the selected repository filter", async () => {
    const calls = setupFetchMock()
    renderTimeline()

    await screen.findByText("worker-a:123")

    fireEvent.change(screen.getByLabelText("Repository"), { target: { value: "1" } })

    await waitFor(() => {
      expect(calls.some((url) => url.includes("/worker_timeline/macro") && url.includes("repository_id=1"))).toBe(true)
    })
  })

  it("refetches with the selected status filter", async () => {
    const calls = setupFetchMock()
    renderTimeline()

    await screen.findByText("worker-a:123")

    fireEvent.click(screen.getByLabelText("running"))

    await waitFor(() => {
      expect(calls.some((url) => url.includes("/worker_timeline/macro") && url.includes("status=running"))).toBe(true)
    })
  })

  it("refetches with the selected worker hostname filter", async () => {
    const calls = setupFetchMock()
    renderTimeline()

    await screen.findByText("worker-a:123")

    fireEvent.change(screen.getByLabelText("Worker hostname"), { target: { value: "worker-b" } })

    await waitFor(() => {
      expect(calls.some((url) => url.includes("/worker_timeline/macro") && url.includes("hostname=worker-b"))).toBe(true)
    })
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
    expect(tooltip).toHaveTextContent("+ (running)")
    expect(tooltip).toHaveTextContent("Blocked: provider_availability")
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
      hostname: `worker-${index}`,
      pid: 100 + index,
      instance: null,
      spans: []
    }))
    setupFetchMock({ lanes })
    renderTimeline()

    expect(await screen.findByText("worker-0:100")).toBeInTheDocument()
    expect(screen.getByText("worker-13:113")).toBeInTheDocument()
    expect(screen.queryByText("worker-19:119")).not.toBeInTheDocument()

    fireEvent.scroll(screen.getByLabelText("Worker lanes"), { target: { scrollTop: 900 } })

    await waitFor(() => {
      expect(screen.getByText("worker-19:119")).toBeInTheDocument()
    })
    expect(screen.queryByText("worker-0:100")).not.toBeInTheDocument()
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
        id: 501, job_id: 42, trigger_kind: "initial", status: "queued", started_at: null, finished_at: null, hostname: null, pid: null,
        blocked: { blocked_reason: "provider_availability", blocked_since: null, blocked_details: {}, next_check_at: null, available: true, historical: false }
      },
      steps: [
        { id: 901, kind: "prepare", status: "queued", position: 0, iteration: 1, started_at: null, finished_at: null, hostname: null, pid: null, runs: [],
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
