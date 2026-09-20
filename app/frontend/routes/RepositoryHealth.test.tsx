import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { describe, expect, it, vi, afterEach } from "vitest"
import { RepositoryHealthRoute } from "./RepositoryHealth"
import type { RepositoryDetailPayload, RepositoryHealthHistory } from "../api/repositories"

function buildHistory(overrides: Partial<RepositoryHealthHistory> = {}): RepositoryHealthHistory {
  return {
    ci_health: "broken",
    grader_health: "broken",
    main_health: "broken",
    landing_paused: true,
    main_branch_health_enabled: true,
    main_branch_repair_enabled: false,
    main_branch_repair_blocks_work: true,
    main_branch_repair_auto_approve: false,
    treat_grader_timeouts_as_failures: false,
    last_health_checked_sha: null,
    ci_signal_current: true,
    grader_signal_current: true,
    current_health_pending: false,
    current_ci_failed_checks: [],
    current_grader_failed_names: [],
    main_branch_repair: { enabled: false, failed_open_jobs_count: 0, max_open_failed_jobs: 3, blocked_reason: null, can_request: false, can_spawn: false, blocking_job: null, failed_jobs: [] },
    records: [],
    ...overrides
  }
}

function repositoryDetailPayload(overrides: Partial<RepositoryDetailPayload> = {}): RepositoryDetailPayload {
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
      epic_dependency_policy: "linear",
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
      main_branch_repair_blocks_work: true,
      main_branch_repair_auto_approve: false,
      treat_grader_timeouts_as_failures: false,
      last_health_checked_sha: null
    },
    tabs: [
      { key: "overview", label: "Overview", path: "/repositories/1" },
      { key: "health", label: "Health", path: "/repositories/1/health", badge: "!" }
    ],
    counts: { running: 0, queued: 0, failed_7d: 0 },
    retry_failed_jobs: {
      count: 0,
      agent_provider: "claude",
      agent_provider_label: "Claude",
      provider_circuit: { provider: "claude", open: false, reason: null, retry_after: null, failure_count: 0, job_count: 0, signature: null }
    },
    can_release_triage_jobs: false,
    needs_triage_count: 0,
    needs_triage_jobs: [],
    credential_status: { mode: "app", label: "GitHub App", installation_account: null, github_app_registered: true, install_url: null, register_path: null, previous_installation_removed: false, missing_github_ids: false },
    jobs: [],
    pagination: { page: 1, per_page: 20, total_jobs: 0, total_pages: 0, first_item: 0, last_item: 0, previous_path: null, next_path: null },
    preview: null,
    health_history: buildHistory(),
    paths: {
      new_job_path: "/jobs/new",
      new_repository_skill_job_path: "/repositories/1/skills/new",
      edit_repository_path: "/repositories/1/edit",
      app_poll_repository_path: "/api/v1/app/repositories/1/poll",
      app_archive_repository_path: "/api/v1/app/repositories/1/archive",
      app_retry_failed_jobs_repository_path: "/api/v1/app/repositories/1/retry_failed_jobs",
      app_release_needs_triage_job_repository_path: "/api/v1/app/repositories/1/release_needs_triage",
      app_resume_landing_repository_path: "/api/v1/app/repositories/1/resume_landing",
      app_run_main_branch_graders_repository_path: "/api/v1/app/repositories/1/run_main_branch_graders",
      app_repair_main_branch_repository_path: "/api/v1/app/repositories/1/repair_main_branch",
      app_check_ci_now_repository_path: "/api/v1/app/repositories/1/check_ci_now",
      repositories_path: "/repositories",
      repository_documents_path: "/repositories/1/documents",
      repository_scheduled_tasks_path: "/repositories/1/scheduled_tasks",
      app_flaky_tests_path: "/api/v1/app/repositories/1/flaky_tests",
      app_preview_path: "/api/v1/app/repositories/1/preview",
      app_preview_logs_path: "/api/v1/app/repositories/1/preview/logs"
    },
    ...overrides
  }
}

function renderRoute(payloadOverrides: Partial<RepositoryDetailPayload> = {}) {
  vi.spyOn(window, "fetch").mockImplementation(() => Promise.resolve(jsonResponse({ ...repositoryDetailPayload(), ...payloadOverrides })))
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/app-shell/repositories/1/health"]}>
        <Routes>
          <Route element={<RepositoryHealthRoute />} path="/app-shell/repositories/:repositoryId/health" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("RepositoryHealthRoute", () => {
  afterEach(() => vi.restoreAllMocks())

  it("renders the main branch health section on the Health tab", async () => {
    renderRoute()

    expect(await screen.findByText("Main branch health")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "acme/widgets" })).toHaveAttribute("href", "/app-shell/repositories/1")
  })

  it("shows a fallback message when no health history is available", async () => {
    renderRoute({ health_history: undefined })

    expect(await screen.findByText("Health information is not available for this repository yet.")).toBeInTheDocument()
  })
})
