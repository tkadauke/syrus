import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { describe, expect, it, vi, afterEach, beforeEach } from "vitest"
import { RepositoryDetailRoute } from "./RepositoryDetail"

const ARCHIVE_PATH = "/api/v1/app/repositories/1/archive"

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
      epic_dependency_policy: "linear",
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
      main_branch_repair_blocks_work: true,
      main_branch_repair_auto_approve: false,
      treat_grader_timeouts_as_failures: false,
      last_health_checked_sha: null
    },
    syrus_yml: {
      source: ".syrus.yml",
      note: null,
      present: true,
      prepare_commands_count: 1,
      graders_count: 2,
      required_graders_count: 1,
      formatter_mode: "not configured",
      generated_steps_count: 0,
      visual_review_mode: "not configured",
      adversarial_review_rounds: null,
      coverage_configured: false,
      delivery_tracks_count: 0,
      merge_train_failure_policy: null
    },
    tabs: [],
    cognitive_debt: cognitiveDebtPayload(),
    counts: { running: 0, queued: 0, failed_7d: 0 },
    retry_failed_jobs: {
      count: 0,
      agent_provider: "claude",
      agent_provider_label: "Claude",
      provider_circuit: { provider: "claude", open: false, reason: null, retry_after: null, failure_count: 0, job_count: 0, signature: null }
    },
    can_edit: true,
    can_release_triage_jobs: false,
    needs_triage_count: 0,
    needs_triage_jobs: [],
    credential_status: { mode: "app", label: "GitHub App", installation_account: null, github_app_registered: true, install_url: null, register_path: null, previous_installation_removed: false, missing_github_ids: false },
    jobs: [],
    pagination: { page: 1, per_page: 20, total_jobs: 0, total_pages: 0, first_item: 0, last_item: 0, previous_path: null, next_path: null },
    preview: null,
    recommended_actions: [],
    paths: {
      new_job_path: "/jobs/new",
      new_repository_skill_job_path: "/repositories/1/skills/new",
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
      repository_scheduled_tasks_path: "/repositories/1/scheduled_tasks",
      app_preview_path: "/api/v1/app/repositories/1/preview",
      app_preview_logs_path: "/api/v1/app/repositories/1/preview/logs"
    }
  }
}

function cognitiveDebtPayload(overrides = {}) {
  return {
    generated_at: "2026-09-28T12:00:00Z",
    target_sha: "abc123",
    proxy_notice: "Cognitive coverage is a proxy for human engagement, not guaranteed understanding.",
    projection_notice: null,
    unsupported_projection_count: 0,
    empty: false,
    summary: { key: "acme/widgets", line_count: 3, covered_count: 1, stale_count: 0, blind_count: 2, cognitive_coverage_pct: 33.3 },
    subsystems: [
      { key: "app", line_count: 3, covered_count: 1, stale_count: 0, blind_count: 2, cognitive_coverage_pct: 33.3 }
    ],
    files: [
      { key: "app/risky.rb", line_count: 2, covered_count: 0, stale_count: 0, blind_count: 2, cognitive_coverage_pct: 0.0 },
      { key: "app/calm.rb", line_count: 1, covered_count: 1, stale_count: 0, blind_count: 0, cognitive_coverage_pct: 100.0 }
    ],
    review_queue: [
      {
        kind: "file" as const,
        path: "app/risky.rb",
        risk_score: 100,
        coverage_state: "blind",
        explanations: ["blind", "high churn", "untested"],
        rollup: { key: "app/risky.rb", line_count: 2, covered_count: 0, stale_count: 0, blind_count: 2, cognitive_coverage_pct: 0.0 },
        signals: { churn: 5, test_coverage_pct: 0, unhealthy_target: false, reliability: null, unsupported_engagements: 0 },
        source: {
          github_url: "https://github.com/acme/widgets/blob/abc123/app/risky.rb#L1",
          review_path: "/jobs/4?tab=review",
          latest_engagement: null
        }
      }
    ],
    ...overrides
  }
}

function recommendation(overrides = {}) {
  return {
    id: "visual_review",
    title: "Add visual review",
    body: "Let Syrus run browser QA on UI diffs.",
    tone: "blue" as const,
    category: "quality",
    dismissal_key: "repository:1:feature_recommendation:visual_review:v1",
    secondary_path: "/docs/visual_review",
    cta: {
      label: "Configure",
      kind: "job" as const,
      path: "/api/v1/app/repositories/1/recommendations/visual_review",
      method: "POST" as const,
      action_id: "visual_review"
    },
    ...overrides
  }
}

function renderRoute(payloadOverrides = {}) {
  vi.spyOn(window, "fetch").mockImplementation((input) => {
    const url = String(input)
    return Promise.resolve(jsonResponse({ ...repositoryDetailPayload(), ...payloadOverrides }))
  })
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
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
  const moreButton = await screen.findByRole("button", { name: "More actions" })
  fireEvent.click(moreButton)
}

const ISSUES_PATH = "/api/v1/app/repositories/1/issues?state=open"

function repositoryIssuesPayload(overrides = {}) {
  return {
    message: null,
    error_message: null,
    repository: repositoryDetailPayload().repository,
    tabs: [],
    state: "open",
    issue_count: 1,
    issues: [
      {
        number: 42,
        title: "Something broke",
        state: "open",
        html_url: "https://github.com/acme/widgets/issues/42",
        body_excerpt: "It broke.",
        user_login: "ada",
        created_at: "2026-01-01T00:00:00Z",
        labels: [],
        delegated: false
      }
    ],
    state_paths: {
      open: "/app-shell/repositories/1?tab=github_issues&state=open",
      closed: "/app-shell/repositories/1?tab=github_issues&state=closed"
    },
    paths: {
      github_issues_path: "https://github.com/acme/widgets/issues",
      app_close_issue_path: "/api/v1/app/repositories/1/issues/close",
      app_delegate_issue_path: "/api/v1/app/repositories/1/issues/delegate",
      app_bulk_issues_path: "/api/v1/app/repositories/1/issues/bulk"
    },
    ...overrides
  }
}

function renderIssuesRoute() {
  const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
    const url = String(input)
    if (url === ISSUES_PATH) {
      return Promise.resolve(jsonResponse(repositoryIssuesPayload()))
    }
    return Promise.resolve(jsonResponse(repositoryDetailPayload()))
  })
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/app-shell/repositories/1?tab=github_issues"]}>
        <Routes>
          <Route element={<RepositoryDetailRoute />} path="/app-shell/repositories/:id" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
  return fetchSpy
}

describe("RepositoryDetailRoute more menu", () => {
  afterEach(() => vi.restoreAllMocks())

  it("shows Edit by default when the user can edit the repository, with other actions collapsed under More actions", async () => {
    renderRoute({ can_edit: true })

    expect(await screen.findByRole("link", { name: "Edit" })).toBeInTheDocument()
    expect(screen.queryByRole("menuitem", { name: "New job" })).not.toBeInTheDocument()
    expect(screen.queryByRole("menuitem", { name: "Poll now" })).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "More actions" }))

    expect(screen.getByRole("menuitem", { name: "New job" })).toBeInTheDocument()
    expect(screen.getByRole("menuitem", { name: "Poll now" })).toBeInTheDocument()
  })

  it("hides Edit when the user cannot edit the repository", async () => {
    renderRoute({ can_edit: false })

    await screen.findByRole("button", { name: "More actions" })
    expect(screen.queryByRole("link", { name: "Edit" })).not.toBeInTheDocument()
  })

  it("links to the skill launch picker from the more menu", async () => {
    renderRoute()
    await openMoreMenu()

    const link = await screen.findByRole("menuitem", { name: "Launch skill" })
    expect(link).toHaveAttribute("href", "/app-shell/repositories/1/skills/new")
  })

  it("does not offer Archive from the more menu -- that lives in the edit form's danger zone now", async () => {
    renderRoute()
    await openMoreMenu()

    expect(screen.queryByRole("menuitem", { name: "Archive" })).not.toBeInTheDocument()
  })
})

describe("RepositoryDetailRoute jobs", () => {
  afterEach(() => vi.restoreAllMocks())

  it("restores the mobile content gutter on repository section titles", async () => {
    renderRoute({
      can_release_triage_jobs: true,
      needs_triage_count: 0,
      needs_triage_jobs: []
    })

    expect(await screen.findByRole("heading", { name: "Needs triage" })).toHaveClass("px-4", "sm:px-0")
    expect(screen.getByRole("heading", { name: "Recent jobs" })).toHaveClass("px-4", "sm:px-0")
  })

  it("shows provider failover on recent job rows", async () => {
    renderRoute({
      jobs: [
        {
          id: 4,
          state: "running",
          priority: "medium",
          kind: "direct",
          issue_title: "Inspect preview dashboard states",
          agent_provider: "codex",
          provider_availability: null,
          provider_failover: {
            mode: "automatic",
            automatic: true,
            original_provider: "claude",
            original_provider_label: "Claude Code",
            selected_provider: "codex",
            selected_provider_label: "Codex",
            reason: "provider_unavailable",
            decided_at: "2026-08-01T12:01:00Z",
            unavailable: {
              provider: "claude",
              label: "Claude Code",
              state: "open",
              reason: "usage_limit",
              retry_after: "2026-08-01T12:10:00Z",
              evidence_source: "provider_circuit",
              evidence_status: "failed",
              observed_at: "2026-08-01T12:00:00Z"
            }
          },
          job_path: "/jobs/4",
          source: { label: "Direct", url: null, external: false },
          pr_number: null,
          pr_url: null,
          external_pr_number: null,
          external_pr_url: null,
          current_step_caption: null,
          retry_state: null,
          runs_count: 1,
          updated_at: "2026-08-01T12:02:00Z"
        }
      ],
      pagination: { page: 1, per_page: 20, total_jobs: 1, total_pages: 1, first_item: 1, last_item: 1, previous_path: null, next_path: null }
    })

    expect(await screen.findByText("Inspect preview dashboard states")).toBeInTheDocument()
    expect(screen.getByText("Claude Code unavailable; running this workflow with Codex.")).toBeInTheDocument()
  })
})

describe("RepositoryDetailRoute .syrus.yml merge-train ladder", () => {
  afterEach(() => vi.restoreAllMocks())

  it("summarizes the configured ladder in order and renders mobile-friendly dropdown labeling", async () => {
    renderRoute({
      syrus_yml: {
        ...repositoryDetailPayload().syrus_yml,
        merge_train_failure_policy: ["restart", "keep_assembly"]
      }
    })

    expect(await screen.findByText("restart -> keep_assembly")).toBeInTheDocument()

    const button = screen.getByRole("button", { name: "Ladder" })
    expect(button).toHaveClass("w-full", "sm:w-auto")

    fireEvent.click(button)

    expect(screen.getByLabelText("restart")).toBeChecked()
    expect(screen.getByLabelText("keep_assembly")).toBeChecked()
    expect(screen.getByText(/merge_train:/)).toBeInTheDocument()
  })

  it("selects rungs and preserves the .syrus.yml ordered-string representation", async () => {
    renderRoute()

    fireEvent.click(await screen.findByRole("button", { name: "Ladder" }))
    fireEvent.click(screen.getByLabelText("restart"))
    fireEvent.click(screen.getByLabelText("keep_assembly"))

    expect(screen.getByText("restart -> keep_assembly")).toBeInTheDocument()
    expect(screen.getByText(/failure_policy: - restart - keep_assembly/)).toBeInTheDocument()
  })

  it("changes rung order with explicit controls", async () => {
    renderRoute({
      syrus_yml: {
        ...repositoryDetailPayload().syrus_yml,
        merge_train_failure_policy: ["restart", "keep_assembly"]
      }
    })

    fireEvent.click(await screen.findByRole("button", { name: "Ladder" }))
    fireEvent.click(screen.getByRole("button", { name: "Move keep_assembly up" }))

    expect(screen.getByText("keep_assembly -> restart")).toBeInTheDocument()
    expect(screen.getByText(/failure_policy: - keep_assembly - restart/)).toBeInTheDocument()
  })

  it("clears to the instance fallback state", async () => {
    renderRoute({
      syrus_yml: {
        ...repositoryDetailPayload().syrus_yml,
        merge_train_failure_policy: ["restart"]
      }
    })

    fireEvent.click(await screen.findByRole("button", { name: "Ladder" }))
    fireEvent.click(screen.getByRole("button", { name: "Use instance fallback" }))

    expect(screen.getByText("Using instance fallback")).toBeInTheDocument()
    expect(screen.getByText(/No merge_train.failure_policy/)).toBeInTheDocument()
  })
})

describe("RepositoryDetailRoute cognitive debt", () => {
  afterEach(() => vi.restoreAllMocks())

  it("renders summary rollups, explanation chips, and source links", async () => {
    renderRoute()

    expect(await screen.findByRole("region", { name: "Cognitive debt review queue" })).toBeInTheDocument()
    expect(screen.getByTestId("cognitive-debt-metrics")).toHaveClass("sm:grid-cols-2", "lg:w-[24rem]", "lg:shrink-0")
    expect(screen.getAllByText("33.3%").length).toBeGreaterThan(0)
    expect(screen.getByRole("link", { name: "app/risky.rb" })).toHaveAttribute("href", "https://github.com/acme/widgets/blob/abc123/app/risky.rb#L1")
    expect(screen.getAllByText("blind").length).toBeGreaterThan(0)
    expect(screen.getByText("high churn")).toBeInTheDocument()
    expect(screen.getByText("untested")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Open review" })).toHaveAttribute("href", "/app-shell/jobs/4?tab=review")
  })

  it("renders the empty state when there is no cognitive evidence", async () => {
    renderRoute({
      cognitive_debt: cognitiveDebtPayload({
        empty: true,
        summary: { key: "acme/widgets", line_count: 0, covered_count: 0, stale_count: 0, blind_count: 0, cognitive_coverage_pct: null },
        subsystems: [],
        files: [],
        review_queue: []
      })
    })

    expect(await screen.findByText("No cognitive coverage evidence is available yet. Coverage snapshots, review comments, approvals, or human-authored commits will populate this queue.")).toBeInTheDocument()
  })

  it("renders the projection notice and chip for unprojected review evidence", async () => {
    renderRoute({
      cognitive_debt: cognitiveDebtPayload({
        projection_notice: "Some line-specific engagement evidence is from a different revision and cannot be projected without a checkout, so it is linked as context but not counted as covered.",
        unsupported_projection_count: 1,
        review_queue: [
          {
            kind: "file" as const,
            path: "app/risky.rb",
            risk_score: 120,
            coverage_state: "blind",
            explanations: ["blind", "unprojected review evidence"],
            rollup: { key: "app/risky.rb", line_count: 2, covered_count: 0, stale_count: 0, blind_count: 2, cognitive_coverage_pct: 0.0 },
            signals: { churn: 1, test_coverage_pct: 0, unhealthy_target: false, reliability: null, unsupported_engagements: 1 },
            source: {
              github_url: "https://github.com/acme/widgets/blob/abc123/app/risky.rb#L1",
              review_path: "/jobs/4?tab=review",
              latest_engagement: { source_type: "diff_review_comment", engagement_kind: "reviewed", occurred_at: "2026-09-28T12:00:00Z", start_line: 1, end_line: 1, projection_supported: false }
            }
          }
        ]
      })
    })

    expect(await screen.findByText(/cannot be projected without a checkout/)).toBeInTheDocument()
    expect(screen.getByText("unprojected review evidence")).toBeInTheDocument()
  })
})

describe("RepositoryDetailRoute recent jobs configurable columns", () => {
  afterEach(() => vi.restoreAllMocks())

  beforeEach(() => {
    window.localStorage.clear()
  })

  afterEach(() => {
    window.localStorage.clear()
  })

  function recentJobsPayload() {
    return {
      jobs: [
        {
          id: 4,
          state: "running",
          priority: "medium",
          kind: "direct",
          issue_title: "Inspect preview dashboard states",
          agent_provider: "codex",
          provider_availability: null,
          provider_failover: null,
          job_path: "/jobs/4",
          source: { label: "Direct", url: null, external: false },
          pr_number: null,
          pr_url: null,
          external_pr_number: null,
          external_pr_url: null,
          current_step_caption: null,
          retry_state: null,
          runs_count: 3,
          updated_at: "2026-08-01T12:02:00Z"
        }
      ],
      pagination: { page: 1, per_page: 20, total_jobs: 1, total_pages: 1, first_item: 1, last_item: 1, previous_path: null, next_path: null }
    }
  }

  it("hides the optional Runs column through the column picker and persists it", async () => {
    renderRoute(recentJobsPayload())

    expect(await screen.findByRole("columnheader", { name: "Runs" })).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Columns" }))
    const menu = await screen.findByRole("menu")
    fireEvent.click(within(menu).getByRole("checkbox", { name: "Runs" }))

    await waitFor(() => {
      expect(screen.queryByRole("columnheader", { name: "Runs" })).not.toBeInTheDocument()
    })
    // State/Issue/Actions stay -- they're the required columns and never appear in the picker.
    expect(screen.getByRole("columnheader", { name: "State" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Issue" })).toBeInTheDocument()

    expect(JSON.parse(window.localStorage.getItem("syrus.repository_detail.jobs.visible_columns") ?? "[]")).toEqual(["last_activity"])
  })
})

describe("RepositoryDetailRoute recommendations", () => {
  afterEach(() => {
    window.localStorage.clear()
    vi.restoreAllMocks()
  })

  it("renders one concise recommendation banner above repository tabs", async () => {
    const view = renderRoute({
      tabs: [{ key: "overview", label: "Overview", path: "/repositories/1" }],
      recommended_actions: [recommendation()]
    })

    expect(await screen.findByRole("region", { name: "Recommended actions" })).toBeInTheDocument()
    expect(screen.getByText("Add visual review")).toBeInTheDocument()
    expect(screen.getByText("Tip 1 of 1")).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Previous tip" })).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Configure" })).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "More actions" }))
    expect(screen.getByRole("menuitem", { name: "Poll now" })).toBeInTheDocument()

    const banner = screen.getByRole("region", { name: "Recommended actions" })
    const recommendationBanner = banner.firstElementChild
    expect(recommendationBanner).toHaveClass("border-info-border", "bg-info-surface", "text-info-text")
    expect(recommendationBanner?.className).not.toMatch(/\b(?:border|bg|text)-blue-/)
    const tabs = view.container.querySelector("nav")
    expect(tabs).toBeTruthy()
    expect(Boolean(banner.compareDocumentPosition(tabs as Node) & Node.DOCUMENT_POSITION_FOLLOWING)).toBe(true)
  })

  it("shows one recommendation at a time and pages through multiple tips", async () => {
    renderRoute({
      recommended_actions: [
        recommendation(),
        recommendation({
          id: "pr_cost_footer",
          title: "Show PR cost footer",
          body: "Add PR cost visibility for operators.",
          dismissal_key: "repository:1:feature_recommendation:pr_cost_footer:v1",
          cta: {
            label: "Enable",
            kind: "toggle" as const,
            path: "/api/v1/app/repositories/1/recommendations/enable_pr_cost_footer",
            method: "POST" as const,
            action_id: "enable_pr_cost_footer"
          }
        })
      ]
    })

    expect(await screen.findByText("Add visual review")).toBeInTheDocument()
    expect(screen.getByText("Tip 1 of 2")).toBeInTheDocument()
    expect(screen.queryByText("Show PR cost footer")).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Next tip" }))

    expect(screen.getByText("Show PR cost footer")).toBeInTheDocument()
    expect(screen.getByText("Tip 2 of 2")).toBeInTheDocument()
    expect(screen.queryByText("Add visual review")).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Previous tip" }))

    expect(screen.getByText("Add visual review")).toBeInTheDocument()
    expect(screen.getByText("Tip 1 of 2")).toBeInTheDocument()
  })

  it("persists dismissals in local storage for the repository", async () => {
    renderRoute({ recommended_actions: [recommendation()] })

    fireEvent.click(await screen.findByRole("button", { name: "Dismiss Add visual review" }))

    expect(screen.queryByText("Add visual review")).not.toBeInTheDocument()
    expect(JSON.parse(window.localStorage.getItem("syrus:repository:1:dismissed-recommendations") || "[]")).toContain("repository:1:feature_recommendation:visual_review:v1")
  })

  it("invokes a job recommendation CTA and navigates to the created job", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = String(input)
      if (url === "/api/v1/app/repositories/1/recommendations/visual_review" && init?.method === "POST") {
        return Promise.resolve(jsonResponse({
          message: "Recommendation job created.",
          redirect_to: "/jobs/42",
          job: { id: 42, slug: "JOB-42", state: "queued", issue_title: "Configure visual review", job_path: "/jobs/42" }
        }, 201))
      }
      return Promise.resolve(jsonResponse({ ...repositoryDetailPayload(), recommended_actions: [recommendation()] }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/repositories/1"]}>
          <Routes>
            <Route element={<RepositoryDetailRoute />} path="/app-shell/repositories/:id" />
            <Route element={<div>Created job</div>} path="/app-shell/jobs/42" />
          </Routes>
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(await screen.findByRole("button", { name: "Configure" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/repositories/1/recommendations/visual_review",
        expect.objectContaining({ method: "POST" })
      )
    })
    expect(await screen.findByText("Created job")).toBeInTheDocument()
    expect(JSON.parse(window.localStorage.getItem("syrus:repository:1:dismissed-recommendations") || "[]")).toContain("repository:1:feature_recommendation:visual_review:v1")
  })

  it("invokes a toggle recommendation CTA and refreshes the detail payload", async () => {
    const updated = {
      ...repositoryDetailPayload(),
      message: "Repository setting enabled.",
      recommended_actions: []
    }
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = String(input)
      if (url === "/api/v1/app/repositories/1/recommendations/enable_pr_cost_footer" && init?.method === "POST") {
        return Promise.resolve(jsonResponse(updated))
      }
      return Promise.resolve(jsonResponse({
        ...repositoryDetailPayload(),
        recommended_actions: [
          recommendation({
            id: "pr_cost_footer",
            title: "Show PR cost footer",
            dismissal_key: "repository:1:feature_recommendation:pr_cost_footer:v1",
            cta: {
              label: "Enable",
              kind: "toggle" as const,
              path: "/api/v1/app/repositories/1/recommendations/enable_pr_cost_footer",
              method: "POST" as const,
              action_id: "enable_pr_cost_footer"
            }
          })
        ]
      }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/repositories/1"]}>
          <Routes>
            <Route element={<RepositoryDetailRoute />} path="/app-shell/repositories/:id" />
          </Routes>
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(await screen.findByRole("button", { name: "Enable" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/repositories/1/recommendations/enable_pr_cost_footer",
        expect.objectContaining({ method: "POST" })
      )
    })
    expect(await screen.findByText("Repository setting enabled.")).toBeInTheDocument()
    expect(screen.queryByText("Show PR cost footer")).not.toBeInTheDocument()
    expect(JSON.parse(window.localStorage.getItem("syrus:repository:1:dismissed-recommendations") || "[]")).toContain("repository:1:feature_recommendation:pr_cost_footer:v1")
  })

  it("renders settings recommendation CTAs as links", async () => {
    renderRoute({
      recommended_actions: [
        recommendation({
          id: "auto_merge",
          title: "Review auto-merge",
          cta: {
            label: "Open settings",
            kind: "link" as const,
            path: "/repositories/1/edit#auto-merge",
            method: "GET" as const
          }
        })
      ]
    })

    const link = await screen.findByRole("link", { name: "Open settings" })
    expect(link).toHaveAttribute("href", "/app-shell/repositories/1/edit#auto-merge")
  })
})

describe("RepositoryDetailRoute preview", () => {
  it("starts a repository-scoped preview from the Preview panel", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = String(input)
      if (url === "/api/v1/app/repositories/1/preview" && init?.method === "POST") {
        return Promise.resolve(jsonResponse({
          preview: { id: 9, state: "starting", url: null, expires_at: null, error_message: null },
          message: "Preview environment starting."
        }, 201))
      }
      return Promise.resolve(jsonResponse(repositoryDetailPayload()))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/repositories/1"]}>
          <Routes>
            <Route element={<RepositoryDetailRoute />} path="/app-shell/repositories/:id" />
          </Routes>
        </MemoryRouter>
      </QueryClientProvider>
    )

    const startButton = await screen.findByRole("button", { name: "Start Preview" })
    fireEvent.click(startButton)

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/repositories/1/preview",
        expect.objectContaining({ method: "POST" })
      )
    })
    expect(await screen.findByText("Starting preview…")).toBeInTheDocument()
  })

  it("shows the Open Preview link when a repository preview is already running", async () => {
    const payload = {
      ...repositoryDetailPayload(),
      preview: { id: 9, state: "running" as const, url: "http://preview-9.lvh.me?token=signed-preview-token", expires_at: new Date(Date.now() + 10 * 60 * 1000).toISOString(), error_message: null }
    }

    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const url = String(input)
      return Promise.resolve(jsonResponse(payload))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/repositories/1"]}>
          <Routes>
            <Route element={<RepositoryDetailRoute />} path="/app-shell/repositories/:id" />
          </Routes>
        </MemoryRouter>
      </QueryClientProvider>
    )

    const link = await screen.findByRole("link", { name: "Open Preview" })
    expect(link).toHaveAttribute("href", "http://preview-9.lvh.me?token=signed-preview-token")
  })
})
