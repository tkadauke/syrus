import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { describe, expect, it, vi, afterEach, beforeEach } from "vitest"
import { RepositoryDetailRoute } from "./RepositoryDetail"
import * as useConfirmModule from "../hooks/useConfirm"

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
      main_branch_repair_blocks_work: true,
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
  const moreButton = await screen.findByRole("button", { name: "More" })
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
      app_comment_issue_path: "/api/v1/app/repositories/1/issues/comment",
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

describe("RepositoryDetailRoute archive", () => {
  let mockConfirm: ReturnType<typeof vi.fn>

  beforeEach(() => {
    mockConfirm = vi.fn().mockResolvedValue(true)
    vi.spyOn(useConfirmModule, "useConfirm").mockReturnValue({ confirm: mockConfirm as any, dialog: <></> })
  })

  afterEach(() => vi.restoreAllMocks())

  it("opens confirm dialog instead of window.confirm when archiving a repository", async () => {
    renderRoute()
    await openMoreMenu()

    const archiveButton = screen.getByRole("button", { name: "Archive" })
    fireEvent.click(archiveButton)

    await waitFor(() => {
      expect(mockConfirm).toHaveBeenCalledWith(expect.objectContaining({ destructive: true }))
    })
  })

  it("links to the skill launch picker from the more menu", async () => {
    renderRoute()
    await openMoreMenu()

    const link = await screen.findByRole("link", { name: "Launch skill" })
    expect(link).toHaveAttribute("href", "/app-shell/repositories/1/skills/new")
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
    expect(screen.getByRole("button", { name: "Poll now" })).toBeInTheDocument()

    const banner = screen.getByRole("region", { name: "Recommended actions" })
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
      preview: { id: 9, state: "running" as const, url: "http://preview-9.lvh.me", expires_at: new Date(Date.now() + 10 * 60 * 1000).toISOString(), error_message: null }
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
    expect(link).toHaveAttribute("href", "http://preview-9.lvh.me")
  })
})
