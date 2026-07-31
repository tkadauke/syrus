import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { describe, expect, it, vi, afterEach, beforeEach } from "vitest"
import { RepositoryDetailRoute } from "./RepositoryDetail"
import * as useConfirmModule from "../hooks/useConfirm"

const ARCHIVE_PATH = "/api/v1/app/repositories/1/archive"
const THROUGHPUT_PATH = "/api/v1/app/repositories/1/throughput_metrics"

function repositoryDetailPayload() {
  return {
    repository: {
      id: 1,
      slug: "acme/widgets",
      owner: "acme",
      name: "widgets",
      default_branch: "main",
      upstream_owner: null,
      upstream_name: null,
      upstream_default_branch: null,
      upstream_slug: null,
      trigger_label: "syrus",
      polling_enabled: true,
      archived: false,
      agent_provider: null,
      agent_provider_label: null,
      effective_agent_provider: "claude",
      effective_agent_provider_label: "Claude",
      epic_dependency_policy: "nonlinear",
      github_url: "https://github.com/acme/widgets",
      created_at: "2026-01-01T00:00:00Z",
      owner_user: { id: 2, display_name: "Ada Lovelace", email_address: "ada@example.com", admin: false },
      github_rate_limit: null,
      ci_health: "healthy",
      grader_health: "healthy",
      main_health: "healthy",
      landing_paused: false,
      main_branch_health_enabled: false,
      main_branch_repair_enabled: false,
      main_branch_repair_auto_approve: false,
      treat_grader_timeouts_as_failures: false,
      last_health_checked_sha: null
    },
    tabs: [],
    counts: { running: 0, queued: 0, failed_7d: 0 },
    retry_failed_jobs: {
      count: 0,
      agent_provider: "claude",
      agent_provider_label: "Claude",
      provider_circuit: { provider: "claude", open: false, reason: null, retry_after: null, failure_count: 0, job_count: 0, signature: null }
    },
    can_release_triage_jobs: false,
    needs_triage_jobs: [],
    credential_status: { mode: "app", label: "GitHub App", installation_account: null, github_app_registered: true, install_url: null, register_path: null, previous_installation_removed: false, missing_github_ids: false },
    jobs: [],
    pagination: { page: 1, per_page: 20, total_jobs: 0, total_pages: 0, first_item: 0, last_item: 0, previous_path: null, next_path: null },
    paths: {
      new_job_path: "/jobs/new",
      edit_repository_path: "/repositories/1/edit",
      app_poll_repository_path: "/api/v1/app/repositories/1/poll",
      app_archive_repository_path: ARCHIVE_PATH,
      app_retry_failed_jobs_repository_path: "/api/v1/app/repositories/1/retry_failed_jobs",
      app_release_needs_triage_job_repository_path: "/api/v1/app/repositories/1/release_needs_triage",
      app_resume_landing_repository_path: "/api/v1/app/repositories/1/resume_landing",
      app_run_main_branch_graders_repository_path: "/api/v1/app/repositories/1/run_main_branch_graders",
      app_repair_main_branch_repository_path: "/api/v1/app/repositories/1/repair_main_branch",
      app_check_ci_now_repository_path: "/api/v1/app/repositories/1/check_ci_now",
      repositories_path: "/repositories",
      repository_documents_path: "/repositories/1/documents",
      repository_scheduled_tasks_path: "/repositories/1/scheduled_tasks"
    }
  }
}

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

function renderRoute() {
  vi.spyOn(window, "fetch").mockImplementation((input) => {
    const url = String(input)
    if (url === THROUGHPUT_PATH) {
      return Promise.resolve(jsonResponse(throughputPayload()))
    }
    return Promise.resolve(jsonResponse(repositoryDetailPayload()))
  })
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/app-shell/repositories/1"]}>
        <Routes>
          <Route element={<RepositoryDetailRoute />} path="/app-shell/repositories/:id" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

async function openMoreMenu() {
  const moreButton = await screen.findByRole("button", { name: "More" })
  fireEvent.click(moreButton)
}

describe("RepositoryDetailRoute archive", () => {
  let mockConfirm: ReturnType<typeof vi.fn>

  beforeEach(() => {
    mockConfirm = vi.fn().mockResolvedValue(true)
    vi.spyOn(useConfirmModule, "useConfirm").mockReturnValue({ confirm: mockConfirm as any, dialog: <></> })
  })

  afterEach(() => vi.restoreAllMocks())

  it("shows repository throughput metrics from the high-activity landing window fixture", async () => {
    renderRoute()

    expect(await screen.findByText("8 Syrus-authored, 9 observed")).toBeInTheDocument()
    expect(screen.getByText("2/h")).toBeInTheDocument()
    expect(screen.getByText("8 Syrus-authored, 9 observed")).toBeInTheDocument()
    expect(screen.getByText("0.75/h")).toBeInTheDocument()
    expect(screen.getByText("1 auto, 2 trains")).toBeInTheDocument()
    expect(screen.getByText("2.25/h")).toBeInTheDocument()
    expect(screen.getByText("9 jobs; train avg 4")).toBeInTheDocument()
    expect(screen.getByText("n=9")).toBeInTheDocument()
    expect(screen.getByText("5 (71%)")).toBeInTheDocument()
    expect(screen.getAllByText("30m").length).toBeGreaterThan(0)
    expect(screen.getByText("2 workflows")).toBeInTheDocument()
  })

  it("switches throughput windows and keeps sparse confidence visible", async () => {
    renderRoute()

    const oneHour = await screen.findByRole("button", { name: "1h" })
    fireEvent.click(oneHour)

    expect(await screen.findByText("0 Syrus-authored, 0 observed")).toBeInTheDocument()
    expect(screen.getAllByText("none").length).toBeGreaterThan(0)
  })

  it("opens confirm dialog instead of window.confirm when archiving a repository", async () => {
    renderRoute()
    await openMoreMenu()

    const archiveButton = screen.getByRole("button", { name: "Archive" })
    fireEvent.click(archiveButton)

    await waitFor(() => {
      expect(mockConfirm).toHaveBeenCalledWith(expect.objectContaining({ destructive: true }))
    })
  })

  it("renders the repository Epic dependency default", async () => {
    renderRoute()

    expect(await screen.findByText("Epic dependency policy")).toBeInTheDocument()
    expect(screen.getByText("Nonlinear by default")).toBeInTheDocument()
  })

  it("calls the archive API when the user confirms", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = String(input)
      if (url === ARCHIVE_PATH && init?.method === "POST") {
        return Promise.resolve(jsonResponse({ active_repositories: [], archived_repositories: [], new_repository_path: "/repositories/new" }))
      }
      return Promise.resolve(jsonResponse(repositoryDetailPayload()))
    })

    renderRoute()
    await openMoreMenu()

    const archiveButton = screen.getByRole("button", { name: "Archive" })
    fireEvent.click(archiveButton)

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        ARCHIVE_PATH,
        expect.objectContaining({ method: "POST" })
      )
    })
  })

  it("does not call the archive API when the user cancels", async () => {
    mockConfirm.mockResolvedValue(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(repositoryDetailPayload()))

    renderRoute()
    await openMoreMenu()

    const archiveButton = screen.getByRole("button", { name: "Archive" })
    await act(async () => { fireEvent.click(archiveButton) })

    await waitFor(() => { expect(mockConfirm).toHaveBeenCalled() })
    expect(fetchSpy).not.toHaveBeenCalledWith(
      ARCHIVE_PATH,
      expect.objectContaining({ method: "POST" })
    )
  })
})
