import { jsonResponse } from "../../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi, afterEach, beforeEach } from "vitest"
import { MainBranchHealthSection } from "./MainBranchHealth"
import * as useConfirmModule from "../../hooks/useConfirm"
import type { RepositoryDetailPayload, RepositoryHealthCheckRecord, RepositoryHealthHistory } from "../../api/repositories"

const RESUME_PATH = "/api/v1/app/repositories/1/resume_landing"

function buildHistory(records: RepositoryHealthCheckRecord[] = []): RepositoryHealthHistory {
  return {
    ci_health: "broken",
    grader_health: "broken",
    main_health: "broken",
    landing_paused: true,
    main_branch_health_enabled: true,
    main_branch_repair_enabled: false,
    main_branch_repair_auto_approve: false,
    treat_grader_timeouts_as_failures: false,
    last_health_checked_sha: null,
    main_branch_repair: { enabled: false, failed_open_jobs_count: 0, max_open_failed_jobs: 3, blocked_reason: null, can_request: false, can_spawn: false, blocking_job: null, failed_jobs: [] },
    records
  }
}

function buildPayload(): RepositoryDetailPayload {
  const repository = {
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
    epic_dependency_policy: "linear" as const,
    github_url: "https://github.com/acme/widgets",
    created_at: "2026-01-01T00:00:00Z",
    owner_user: { id: 2, display_name: "Ada Lovelace", email_address: "ada@example.com", admin: false },
    github_rate_limit: null,
    ci_health: "broken",
    grader_health: "broken",
    main_health: "broken",
    landing_paused: true,
    main_branch_health_enabled: true,
    main_branch_repair_enabled: false,
    main_branch_repair_auto_approve: false,
    treat_grader_timeouts_as_failures: false,
    last_health_checked_sha: null
  }
  return {
    repository,
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
      app_archive_repository_path: "/api/v1/app/repositories/1/archive",
      app_retry_failed_jobs_repository_path: "/api/v1/app/repositories/1/retry_failed_jobs",
      app_release_needs_triage_job_repository_path: "/api/v1/app/repositories/1/release_needs_triage",
      app_resume_landing_repository_path: RESUME_PATH,
      app_run_main_branch_graders_repository_path: "/api/v1/app/repositories/1/run_main_branch_graders",
      app_repair_main_branch_repository_path: "/api/v1/app/repositories/1/repair_main_branch",
      app_check_ci_now_repository_path: "/api/v1/app/repositories/1/check_ci_now",
      repositories_path: "/repositories",
      repository_documents_path: "/repositories/1/documents",
      repository_scheduled_tasks_path: "/repositories/1/scheduled_tasks",
      app_flaky_tests_path: "/api/v1/app/repositories/1/flaky_tests"
    }
  }
}

function renderSection(history = buildHistory(), payload = buildPayload()) {
  const queryKey = ["repositories", "1", "detail", ""] as const
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter>
        <MainBranchHealthSection
          history={history}
          onNotice={vi.fn()}
          payload={payload}
          prefix="/app-shell"
          queryKey={queryKey}
        />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function buildHealthRecord(overrides: Partial<RepositoryHealthCheckRecord> = {}): RepositoryHealthCheckRecord {
  return {
    id: 1,
    sha: "abc123d",
    sha_url: "https://github.com/acme/widgets/commit/abc123def456",
    checked_at: "2026-01-02T00:00:00Z",
    ci_health: "healthy",
    grader_health: "broken",
    source: "grader_workflow",
    ci_failed_checks: [],
    grader_failed_names: [ "rspec" ],
    workflow_path: "/admin/workflows/12",
    ...overrides
  }
}

describe("MainBranchHealthSection resume landing", () => {
  let mockConfirm: ReturnType<typeof vi.fn>

  beforeEach(() => {
    mockConfirm = vi.fn().mockResolvedValue(true)
    vi.spyOn(useConfirmModule, "useConfirm").mockReturnValue({ confirm: mockConfirm as any, dialog: <></> })
  })

  afterEach(() => vi.restoreAllMocks())

  it("opens confirm dialog instead of window.confirm when resuming landing", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(buildPayload()))
    renderSection()

    const resumeButton = await screen.findByRole("button", { name: "Resume work anyway" })
    fireEvent.click(resumeButton)

    await waitFor(() => {
      expect(mockConfirm).toHaveBeenCalled()
    })
  })

  it("does not pass destructive: true for the resume action", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(buildPayload()))
    renderSection()

    const resumeButton = await screen.findByRole("button", { name: "Resume work anyway" })
    fireEvent.click(resumeButton)

    await waitFor(() => {
      expect(mockConfirm).toHaveBeenCalledWith(
        expect.not.objectContaining({ destructive: true })
      )
    })
  })

  it("calls the resume API when the user confirms", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(buildPayload()))
    renderSection()

    const resumeButton = await screen.findByRole("button", { name: "Resume work anyway" })
    fireEvent.click(resumeButton)

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        RESUME_PATH,
        expect.objectContaining({ method: "POST" })
      )
    })
  })

  it("does not call the resume API when the user cancels", async () => {
    mockConfirm.mockResolvedValue(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(buildPayload()))
    renderSection()

    const resumeButton = await screen.findByRole("button", { name: "Resume work anyway" })
    await act(async () => { fireEvent.click(resumeButton) })

    await waitFor(() => { expect(mockConfirm).toHaveBeenCalled() })
    expect(fetchSpy).not.toHaveBeenCalledWith(RESUME_PATH, expect.anything())
  })

  it("does not offer resume for inconclusive main branch health", () => {
    const history = buildHistory()
    history.ci_health = "not_configured"
    history.grader_health = "inconclusive"
    history.main_health = "inconclusive"
    history.landing_paused = true
    const payload = buildPayload()
    payload.repository.ci_health = "not_configured"
    payload.repository.grader_health = "inconclusive"
    payload.repository.main_health = "inconclusive"
    payload.repository.landing_paused = true
    renderSection(history, payload)

    expect(screen.queryByRole("button", { name: "Resume work anyway" })).not.toBeInTheDocument()
  })
})

describe("MainBranchHealthSection health history", () => {
  it("renders localized source badges for history rows", () => {
    const { container } = renderSection(buildHistory([
      buildHealthRecord({ id: 1, source: "grader_workflow" }),
      buildHealthRecord({ id: 2, source: "ci_poll", sha: "def456a", grader_failed_names: [] })
    ]))

    expect(container.querySelector('[data-source="grader_workflow"]')).toHaveTextContent("Graders")
    expect(container.querySelector('[data-source="ci_poll"]')).toHaveTextContent("CI")
  })

  it("renders concern quorum rows with the amber source variant", () => {
    renderSection(buildHistory([
      buildHealthRecord({ source: "concern_quorum", workflow_path: null })
    ]))

    const badge = screen.getByText("Quorum")
    expect(badge).toBeInTheDocument()
    expect(badge).toHaveAttribute("data-source", "concern_quorum")
    expect(badge).toHaveClass("border-amber-200")
  })
})
