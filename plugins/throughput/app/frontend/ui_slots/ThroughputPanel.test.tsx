import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import ThroughputPanel from "./ThroughputPanel"

const THROUGHPUT_PATH = "/api/v1/app/repositories/1/throughput_metrics"

function throughputWindow(overrides = {}) {
  return {
    range: { start: "2026-07-31T08:00:00Z", end: "2026-07-31T12:00:00Z", hours: 4 },
    pr_creation: {
      count: 8,
      per_hour: 2,
      sample_count: 8,
      confidence: "medium",
      total_observed_count: 9,
      series: {
        syrus_authored: { count: 8, per_hour: 2, sample_count: 8, confidence: "medium" },
        external: { count: 1, per_hour: 0.25, sample_count: 1, confidence: "low" },
        fork_review: { count: 0, per_hour: 0, sample_count: 0, confidence: "none" }
      }
    },
    output: {
      commits: { count: 14, per_hour: 3.5, sample_count: 14, confidence: "medium" },
      loc: { count: 640, per_hour: 160, sample_count: 8, confidence: "medium", additions: 980, deletions: 340, net: 640, unavailable_sample_count: 1 },
      by_job: []
    },
    landing: {
      landing_units: { count: 3, per_hour: 0.75, sample_count: 3, confidence: "low" },
      jobs_landed: { count: 9, per_hour: 2.25, sample_count: 9, confidence: "medium" },
      attempts: {
        total_count: 4,
        successful: { count: 3, per_hour: 0.75, sample_count: 3, confidence: "low" },
        failed: { count: 1, per_hour: 0.25, sample_count: 1, confidence: "low" },
        cancelled: { count: 0, per_hour: 0, sample_count: 0, confidence: "none" },
        deferred: { count: 0, per_hour: 0, sample_count: 0, confidence: "none" }
      },
      unit_types: {
        auto_merge: { landing_units: 1, jobs_landed: 1 },
        merge_train: { landing_units: 2, jobs_landed: 8 }
      },
      merge_train_size: { sample_count: 2, confidence: "low", average: 4, max: 5, values: [3, 5] },
      approved_to_landing_latency_seconds: { sample_count: 6, confidence: "medium", average: 900, p50: 840, p95: 1500 },
      landing_start_to_closed_latency_seconds: { sample_count: 3, confidence: "low", average: 1200, p50: 900, p95: 1800 },
      grader_phase_duration_seconds: { sample_count: 4, confidence: "low", average: 780, p50: 720, p95: 1200 },
      mergeability_rebase_wait_seconds: { sample_count: 2, confidence: "low", average: 180, p50: 120, p95: 240 },
      base_moved_regrade_count: 1,
      reused_landing_validation_count: 2,
      current_optimistic_capacity: {
        sample_count: 6,
        confidence: "medium",
        average_successful_unit_wall_time_seconds: 1200,
        estimated_landing_units_per_hour: 3,
        estimated_jobs_landed_per_hour: 9,
        average_jobs_per_landing_unit: 3
      }
    },
    landing_waste: {
      failed_landing_attempts_per_successful_landing: { numerator: 1, denominator: 3, value: 0.3333, confidence: "low" },
      failed_or_cancelled_landing_workflow_seconds: 1800,
      failed_or_cancelled_landing_workflow_count: 1,
      deferred_landing_attempt_count: 0,
      failed_train_cooldown_seconds: 1800,
      failed_train_cooldown_remaining_seconds: 600,
      rebase_churn_workflow_count: 2,
      rebase_churn_seconds: 1500,
      landing_blocking_rebase_count: 1
    },
    review_funnel: {
      jobs_with_pr_feedback: 3,
      jobs_with_feedback_before_approval: 2,
      feedback_rounds: 5,
      jobs_approved_immediately_without_feedback: 5,
      approval_sources: {
        operator: { count: 4, sample_count: 4, confidence: "low" },
        auto: { count: 2, sample_count: 2, confidence: "low" },
        github_review: { count: 1, sample_count: 1, confidence: "low" },
        unknown: { count: 0, sample_count: 0, confidence: "none" }
      },
      pr_open_to_first_feedback_seconds: { sample_count: 3, confidence: "low", average: 600, p50: 600, p95: 900 },
      feedback_to_addressed_seconds: { sample_count: 3, confidence: "low", average: 900, p50: 840, p95: 1200 },
      pr_open_to_approval_seconds: { sample_count: 7, confidence: "medium", average: 1800, p50: 1500, p95: 3600 },
      approval_latency_seconds: { sample_count: 7, confidence: "medium", average: 1800, p50: 1500, p95: 3600 },
      approval_to_landing_start_seconds: { sample_count: 6, confidence: "medium", average: 900, p50: 840, p95: 1500 },
      approval_to_landing_latency_seconds: { sample_count: 6, confidence: "medium", average: 900, p50: 840, p95: 1500 },
      approval_to_landed_seconds: { sample_count: 6, confidence: "medium", average: 2100, p50: 1800, p95: 3300 },
      approval_count: 7,
      approval_vote_count: 9,
      pr_opened_count: 9
    },
    samples: {
      jobs_seen: 10,
      prs_opened: 9,
      output_runs_with_diffs: 8,
      landed_jobs: 9,
      landing_workflows: 4,
      landing_units: 3,
      approvals: 7,
      approval_votes: 9,
      feedback_comments: 6
    },
    ...overrides
  }
}

function throughputPayload() {
  const empty = throughputWindow({
    range: { start: "2026-07-31T11:00:00Z", end: "2026-07-31T12:00:00Z", hours: 1 },
    pr_creation: {
      ...throughputWindow().pr_creation,
      count: 0,
      per_hour: 0,
      sample_count: 0,
      confidence: "none",
      total_observed_count: 0
    }
  })

  return {
    version: 1,
    repository_id: 1,
    generated_at: "2026-07-31T12:00:00Z",
    windows: {
      "1h": empty,
      "4h": throughputWindow(),
      "24h": throughputWindow({ range: { start: "2026-07-30T12:00:00Z", end: "2026-07-31T12:00:00Z", hours: 24 } }),
      "7d": throughputWindow({ range: { start: "2026-07-24T12:00:00Z", end: "2026-07-31T12:00:00Z", hours: 168 } }),
      last_active: throughputWindow({ range: { start: "2026-07-31T10:20:00Z", end: "2026-07-31T11:20:00Z", hours: 1 } })
    }
  }
}

function renderPanel() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <ThroughputPanel repository={{ id: 1 }} />
    </QueryClientProvider>
  )
}

describe("ThroughputPanel", () => {
  beforeEach(() => {
    vi.spyOn(globalThis, "fetch").mockImplementation((input: RequestInfo | URL) => {
      const url = typeof input === "string" ? input : input.toString()
      if (url === THROUGHPUT_PATH) {
        return Promise.resolve(new Response(JSON.stringify(throughputPayload()), {
          status: 200,
          headers: { "Content-Type": "application/json" }
        }))
      }
      return Promise.reject(new Error(`unexpected fetch: ${url}`))
    })
  })

  afterEach(() => vi.restoreAllMocks())

  it("renders nothing without a repository", () => {
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const { container } = render(
      <QueryClientProvider client={client}>
        <ThroughputPanel />
      </QueryClientProvider>
    )
    expect(container).toBeEmptyDOMElement()
  })

  it("shows throughput metrics from the high-activity landing window fixture", async () => {
    renderPanel()

    expect(await screen.findByText("8 Syrus-authored, 9 observed")).toBeInTheDocument()
    expect(screen.getByText("2/h")).toBeInTheDocument()
    expect(screen.getByText("0.75/h")).toBeInTheDocument()
    expect(screen.getByText("1 auto, 2 trains")).toBeInTheDocument()
    expect(screen.getByText("2.25/h")).toBeInTheDocument()
    expect(screen.getByText("9 jobs; train avg 4")).toBeInTheDocument()
    expect(screen.getByText("n=9")).toBeInTheDocument()
    expect(screen.getByText("5 (71%)")).toBeInTheDocument()
    expect(screen.getAllByText("30m").length).toBeGreaterThan(0)
    expect(screen.getByText("2 workflows")).toBeInTheDocument()
  })

  it("switches windows and keeps sparse confidence visible", async () => {
    renderPanel()

    const oneHour = await screen.findByRole("button", { name: "1h" })
    fireEvent.click(oneHour)

    expect(await screen.findByText("0 Syrus-authored, 0 observed")).toBeInTheDocument()
    expect(screen.getAllByText("none").length).toBeGreaterThan(0)
  })
})
