import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter, useLocation } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { JobDetailPayload, JobRun, JobSourcePayload, JobStep, JobWorkflow } from "../api/jobs"
import { FeedbackHistoryPanel, JobDetailView, TestPlanPanel } from "./JobDetail"

describe("JobDetailView", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("links the origin chat from the job header", () => {
    renderJobDetail(jobPayload({
      job: {
        ...baseJob(),
        source_chat: {
          chat_id: 4,
          chat_title: "Roadmap chat",
          proposal_id: 9,
          proposal_kind: "syrus_issue",
          message_id: 12,
          path: "/chats/4#message-12",
          label: "Job proposal in Roadmap chat"
        }
      }
    }))

    expect(screen.getByRole("link", { name: "Job proposal in Roadmap chat" }))
      .toHaveAttribute("href", "/app-shell/chats/4#message-12")
  })

  it("links scheduled jobs back to their scheduled task", () => {
    renderJobDetail(jobPayload({
      job: {
        ...baseJob(),
        kind: "cron",
        issue_title: null,
        scheduled_task_id: 12,
        scheduled_task: {
          id: 12,
          name: "Update architecture",
          scheduled_task_path: "/scheduled_tasks/12"
        }
      }
    }))

    expect(screen.getByRole("link", { name: "Scheduled Job" }))
      .toHaveAttribute("href", "/app-shell/scheduled_tasks/12")
  })

  it("links the originating message when origin_chat is present", () => {
    renderJobDetail(jobPayload({
      origin_chat: {
        chat_session_id: 7,
        message_id: 42
      }
    }))

    expect(screen.getByRole("link", { name: "View in chat" }))
      .toHaveAttribute("href", "/app-shell/chats/7#message-42")
  })

  it("omits the originating message link when origin_chat is null", () => {
    renderJobDetail(jobPayload({ origin_chat: null }))

    expect(screen.queryByRole("link", { name: "View in chat" })).not.toBeInTheDocument()
  })

  it.each(["implemented", "failed"])("renders the Give feedback button for %s jobs", (state) => {
    renderJobDetail(jobPayload({
      job: { ...baseJob(), state, summary_state: state }
    }))

    expect(screen.getByRole("button", { name: "Give feedback" })).toBeInTheDocument()
  })

  it("hides the Give feedback button for other job states", () => {
    renderJobDetail(jobPayload({
      job: { ...baseJob(), state: "running", summary_state: "running" }
    }))

    expect(screen.queryByRole("button", { name: "Give feedback" })).not.toBeInTheDocument()
  })

  it("opens the overflow menu aligned to the right-0 edge when the button has room to the left", () => {
    renderJobDetail(jobPayload())
    const menuButton = screen.getByRole("button", { name: "⋯" })

    vi.spyOn(menuButton, "getBoundingClientRect").mockReturnValue({
      right: 300, left: 260, top: 0, bottom: 36, width: 40, height: 36, x: 260, y: 0, toJSON: () => ({})
    } as DOMRect)

    fireEvent.click(menuButton)

    const menu = screen.getByRole("menu")
    expect(menu).toHaveClass("right-0")
    expect(menu).not.toHaveClass("left-0")
  })

  it("opens the overflow menu aligned to the left-0 edge when the button is near the left viewport edge", () => {
    renderJobDetail(jobPayload())
    const menuButton = screen.getByRole("button", { name: "⋯" })

    vi.spyOn(menuButton, "getBoundingClientRect").mockReturnValue({
      right: 100, left: 60, top: 0, bottom: 36, width: 40, height: 36, x: 60, y: 0, toJSON: () => ({})
    } as DOMRect)

    fireEvent.click(menuButton)

    const menu = screen.getByRole("menu")
    expect(menu).toHaveClass("left-0")
    expect(menu).not.toHaveClass("right-0")
  })

  it("renders dependency blockers as linked Job slugs", () => {
    const parsedDependency = {
      id: 12,
      source: "parsed",
      manual: false,
      pending: false,
      succeeded: false,
      unresolved_slug: null,
      depends_on_job: {
        id: 1101,
        kind: "issue",
        state: "queued",
        summary_state: "queued",
        repository_slug: "tkadauke/syrus",
        issue_number: 1101,
        issue_title: "First dependency",
        branch_name: null,
        pr_number: null,
        job_path: "/jobs/1101"
      }
    }
    const manualDependency = {
      id: 13,
      source: "manual",
      manual: true,
      pending: false,
      succeeded: false,
      unresolved_slug: null,
      depends_on_job: {
        ...parsedDependency.depends_on_job,
        id: 1108,
        summary_state: "queued",
        issue_number: null,
        issue_title: "Direct dependency",
        job_path: "/jobs/1108"
      }
    }

    renderJobDetail(jobPayload({
      dependencies: [ parsedDependency, manualDependency ],
      unsatisfied_dependencies: [ parsedDependency, manualDependency ]
    }))

    expect(screen.getByText("Blocked on 2 dependencies:")).toBeInTheDocument()
    expect(screen.getAllByRole("link", { name: "tkadauke/syrus JOB-1101 (queued)" })).toHaveLength(2)
    expect(screen.queryByText("tkadauke/syrus #1101 (queued)")).not.toBeInTheDocument()
    expect(screen.getAllByRole("link", { name: "tkadauke/syrus JOB-1101 (queued)" })[0])
      .toHaveAttribute("href", "/app-shell/jobs/1101")
  })

  it("expands the feedback panel and disables Submit when the body is empty", () => {
    renderJobDetail(jobPayload({
      job: { ...baseJob(), state: "implemented", summary_state: "implemented" }
    }))

    fireEvent.click(screen.getByRole("button", { name: "Give feedback" }))

    expect(screen.getByPlaceholderText("What should be changed?")).toHaveAttribute("rows", "4")
    expect(screen.getByRole("button", { name: "Submit feedback" })).toBeDisabled()
  })

  it("submits feedback, collapses the panel, and shows a success notice", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({ workflow: { id: 2, trigger_kind: "chat_feedback" } }, { status: 201 }))
    renderJobDetail(jobPayload({
      job: { ...baseJob(), state: "implemented", summary_state: "implemented" }
    }))

    fireEvent.click(screen.getByRole("button", { name: "Give feedback" }))
    fireEvent.change(screen.getByPlaceholderText("What should be changed?"), { target: { value: "Tighten the copy." } })
    fireEvent.click(screen.getByRole("button", { name: "Submit feedback" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/jobs/1/chat_feedback", expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ body: "Tighten the copy." })
      }))
    })
    expect(fetchSpy.mock.calls[0]?.[1]).toEqual(expect.objectContaining({
      headers: expect.objectContaining({ "Content-Type": "application/json" })
    }))
    await waitFor(() => {
      expect(screen.queryByPlaceholderText("What should be changed?")).not.toBeInTheDocument()
    })
    expect(screen.getByText("Feedback submitted — a new workflow will start shortly.")).toBeInTheDocument()
  })

  it("shows an inline error when feedback submission fails", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({ error: { message: "Job already has active feedback." } }, { status: 422 }))
    renderJobDetail(jobPayload({
      job: { ...baseJob(), state: "failed", summary_state: "failed" }
    }))

    fireEvent.click(screen.getByRole("button", { name: "Give feedback" }))
    fireEvent.change(screen.getByPlaceholderText("What should be changed?"), { target: { value: "Try another approach." } })
    fireEvent.click(screen.getByRole("button", { name: "Submit feedback" }))

    expect(await screen.findByRole("alert")).toHaveTextContent("Job already has active feedback.")
    expect(screen.getByPlaceholderText("What should be changed?")).toBeInTheDocument()
  })

  it("renders the issue body as markdown", () => {
    renderJobDetail(jobPayload({
      job: {
        ...baseJob(),
        issue_body: "## Problem\n\nFix `JobDetail` and read [the docs](/docs).\n\n1. Render markdown"
      }
    }))

    const panel = screen.getByRole("heading", { name: "Issue" }).closest("section")
    expect(panel).not.toBeNull()
    expect(within(panel as HTMLElement).getByRole("heading", { name: "Problem" })).toBeInTheDocument()
    expect(within(panel as HTMLElement).getByText("JobDetail").tagName).toBe("CODE")
    expect(within(panel as HTMLElement).getByRole("link", { name: "the docs" })).toHaveAttribute("href", "/docs")
    expect(within(panel as HTMLElement).getByText("Render markdown")).toBeInTheDocument()
  })

  it("hides workflow terminal actions when the feature flag is disabled", () => {
    renderJobDetail(jobPayload({
      workflows: [ workflow({ id: 4, slug: "WF-4" }) ],
      workflows_pagination: workflowPagination(1)
    }), { activeTab: "workflows" })

    expect(screen.queryByRole("button", { name: "Open terminal in workspace" })).not.toBeInTheDocument()
  })

  it("opens a terminal session from a workflow row and navigates to it", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      session: {
        id: 77,
        name: "WF-4 workspace",
        working_directory: "/tmp/workflows/4",
        started_at: "2026-06-27T10:00:00Z",
        finished_at: null,
        outcome: null,
        workflow_id: 4
      }
    }))

    renderJobDetail(jobPayload({
      feature_flags: { terminal: true },
      workflows: [ workflow({ id: 4, slug: "WF-4" }) ],
      workflows_pagination: workflowPagination(1)
    }), { activeTab: "workflows", showLocation: true })

    fireEvent.click(screen.getByRole("button", { name: "Open terminal in workspace" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/terminal_sessions",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ terminal_session: { workflow_id: 4, name: "WF-4 workspace" } })
      })
    ))
    await waitFor(() => expect(screen.getByTestId("location")).toHaveTextContent("/app-shell/terminal?session=77"))

    fetchSpy.mockRestore()
  })

  it("renders ANSI color directives in run transcripts", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      job_id: 1,
      run_id: 22,
      agent_diff: null,
      agent_diff_bytes: 0,
      logs_count: 1,
      logs: [
        {
          id: 1,
          sequence: 1,
          kind: "grade_log",
          chunk: "RUN \u001b[32mpassed\u001b[39m \u001b[33mwarned\u001b[39m",
          created_at: "2026-07-01T10:00:00Z"
        }
      ]
    }))

    renderJobDetail(jobPayload({
      workflows: [
        workflow({
          id: 4,
          steps: [
            step({
              id: 9,
              runs: [ run({ id: 22, job_log_count: 1 }) ]
            })
          ]
        })
      ],
      workflows_pagination: workflowPagination(1)
    }), { activeTab: "workflows" })

    fireEvent.click(screen.getByRole("button", { name: /Implement/ }))
    fireEvent.click(screen.getByRole("button", { name: "Transcript" }))

    expect(await screen.findByText("passed")).toHaveClass("text-emerald-700")
    expect(screen.getByText("warned")).toHaveClass("text-amber-700")
    expect(screen.getByTestId("run-transcript-log-stream")).not.toHaveTextContent("\u001b[32m")
  })
})

describe("TestPlanPanel", () => {
  it("renders numbered steps and notes", () => {
    render(
      <TestPlanPanel
        testPlan={{
          workflow_id: 5,
          steps: [ "Run bin/rspec spec/services/app/job_detail_payload_spec.rb", "Run bin/test-react" ],
          notes: "Check the Summary tab."
        }}
      />
    )

    const panel = screen.getByRole("heading", { name: "Test plan" }).closest("section")
    expect(panel).not.toBeNull()
    const listItems = within(panel as HTMLElement).getAllByRole("listitem")
    expect(listItems.map((item) => item.textContent)).toEqual([
      "Run bin/rspec spec/services/app/job_detail_payload_spec.rb",
      "Run bin/test-react"
    ])
    expect(screen.getByText("Check the Summary tab.")).toBeInTheDocument()
  })

  it("renders nothing when no test plan is available", () => {
    render(<TestPlanPanel testPlan={null} />)

    expect(screen.queryByRole("heading", { name: "Test plan" })).not.toBeInTheDocument()
  })
})

describe("FeedbackHistoryPanel", () => {
  it("is absent when there are no feedback workflows", () => {
    renderFeedbackHistory([
      workflow({ id: 1, trigger_kind: "initial", created_at: "2026-06-01T10:00:00Z" })
    ])

    expect(screen.queryByRole("heading", { name: "Feedback history" })).not.toBeInTheDocument()
  })

  it("renders chat feedback text for chat feedback workflows", () => {
    renderFeedbackHistory([
      workflow({
        id: 2,
        slug: "WF-2",
        path: "/workflows/2",
        trigger_kind: "chat_feedback",
        state: "succeeded",
        created_at: "2026-06-02T10:00:00Z",
        artifacts: { chat_feedback: "Please tighten the dashboard copy.\nKeep the button text short." }
      })
    ])

    expect(screen.getByRole("heading", { name: "Feedback history" })).toBeInTheDocument()
    expect(screen.getByText("Chat feedback")).toBeInTheDocument()
    expect(screen.getByText(/Please tighten the dashboard copy/)).toHaveClass("whitespace-pre-wrap", "break-words")
    expect(screen.getByRole("link", { name: "WF-2" })).toHaveAttribute("href", "/app-shell/workflows/2")
  })

  it("shows the PR review note for PR comment workflows", () => {
    renderFeedbackHistory([
      workflow({
        id: 3,
        trigger_kind: "pr_comment",
        state: "running",
        created_at: "2026-06-03T10:00:00Z"
      })
    ])

    expect(screen.getByText("PR review")).toBeInTheDocument()
    expect(screen.getByText("PR review feedback")).toBeInTheDocument()
  })

  it("shows multiple entries in newest-first order", () => {
    renderFeedbackHistory([
      workflow({
        id: 4,
        trigger_kind: "chat_feedback",
        created_at: "2026-06-01T10:00:00Z",
        artifacts: { chat_feedback: "Old feedback" }
      }),
      workflow({
        id: 5,
        trigger_kind: "pr_comment",
        created_at: "2026-06-03T10:00:00Z"
      }),
      workflow({
        id: 6,
        trigger_kind: "chat_feedback",
        created_at: "2026-06-02T10:00:00Z",
        artifacts: { chat_feedback: "Middle feedback" }
      })
    ])

    const panel = screen.getByRole("heading", { name: "Feedback history" }).closest("section")
    expect(panel).not.toBeNull()
    const text = (panel as HTMLElement).textContent || ""
    expect(text.indexOf("PR review feedback")).toBeLessThan(text.indexOf("Middle feedback"))
    expect(text.indexOf("Middle feedback")).toBeLessThan(text.indexOf("Old feedback"))
  })
})

describe("SourceTab", () => {
  it("keeps expanded directories open after selecting a file", async () => {
    mockJobSourceRequests()
    renderJobSource()

    const appButton = await screen.findByRole("button", { name: "app" })
    fireEvent.click(appButton)
    fireEvent.click(screen.getByRole("button", { name: "models" }))
    fireEvent.click(screen.getByRole("button", { name: "user.rb" }))

    const keyword = await screen.findByText("class")
    expect(keyword.closest("code")).toHaveTextContent("class User")
    expect(screen.getByRole("button", { name: "app" })).toHaveAttribute("aria-expanded", "true")
    expect(screen.getByRole("button", { name: "models" })).toHaveAttribute("aria-expanded", "true")
    expect(screen.getByRole("button", { name: "user.rb" })).toBeInTheDocument()
  })

  it("highlights supported source file languages", async () => {
    mockJobSourceRequests()
    renderJobSource()

    fireEvent.click(await screen.findByRole("button", { name: "app" }))
    fireEvent.click(screen.getByRole("button", { name: "models" }))
    fireEvent.click(screen.getByRole("button", { name: "user.rb" }))

    expect(await screen.findByText("class")).toHaveClass("font-semibold", "text-blue-700")
    expect(screen.getByText("User")).toHaveClass("text-cyan-700")
  })

  it("falls back to plain source text for unsupported languages", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(jobSourcePayload({
      file: { path: "README.md", name: "README.md", size: 20, language: "markdown", content: "class User\n" }
    })))
    renderJobSource()

    const code = await screen.findByText("class User")

    expect(code.tagName).toBe("CODE")
    expect(code.querySelector("span")).toBeNull()
  })

  it("uses a rotating chevron for directory toggles", async () => {
    mockJobSourceRequests()
    renderJobSource()

    const appButton = await screen.findByRole("button", { name: "app" })
    const chevron = within(appButton).getByText(">")

    expect(chevron).not.toHaveClass("rotate-90")

    fireEvent.click(appButton)

    expect(chevron).toHaveClass("rotate-90")
    expect(appButton).toHaveAttribute("aria-expanded", "true")
  })
})

function renderFeedbackHistory(workflows: JobWorkflow[]) {
  return render(
    <MemoryRouter>
      <FeedbackHistoryPanel prefix="/app-shell" workflows={workflows} />
    </MemoryRouter>
  )
}

function renderJobDetail(payload: JobDetailPayload, options: { activeTab?: "summary" | "workflows" | "attachments" | "source"; showLocation?: boolean } = {}) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })

  return render(
    <QueryClientProvider client={queryClient}>
      <MemoryRouter initialEntries={["/app-shell/jobs/1"]}>
        {options.showLocation ? <LocationProbe /> : null}
        <JobDetailView
          activeTab={options.activeTab || "summary"}
          onSelectTab={() => {}}
          payload={payload}
          prefix="/app-shell"
          queryKey={["jobs", "1", "detail", ""]}
        />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function LocationProbe() {
  const location = useLocation()
  return <div data-testid="location">{location.pathname}{location.search}</div>
}

function renderJobSource() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })

  return render(
    <QueryClientProvider client={queryClient}>
      <MemoryRouter initialEntries={["/app-shell/jobs/1?tab=source"]}>
        <JobDetailView
          activeTab="source"
          onSelectTab={() => {}}
          payload={jobPayload()}
          prefix="/app-shell"
          queryKey={["jobs", "1", "detail", ""]}
        />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function mockJobSourceRequests() {
  return vi.spyOn(window, "fetch").mockImplementation((input) => {
    const url = requestUrl(input)
    const withFile = url.includes("path=app%2Fmodels%2Fuser.rb") || url.includes("path=app/models/user.rb")

    return Promise.resolve(jsonResponse(jobSourcePayload({ withFile })))
  })
}

function requestUrl(input: Parameters<typeof fetch>[0]) {
  if (typeof input === "string") return input
  if (input instanceof Request) return input.url
  return String(input)
}

function jobPayload(overrides: Partial<JobDetailPayload> = {}): JobDetailPayload {
  return {
    job: baseJob(),
    repository: {
      id: 2,
      slug: "acme/widgets",
      owner: "acme",
      name: "widgets",
      default_branch: "main",
      review_policy: "self",
      feedback_policy: "confirm",
      repository_path: "/repositories/2"
    },
    epic: null,
    origin_chat: null,
    pinned: false,
    tags: [],
    tag_options: [],
    dependencies: [],
    dependents: [],
    unsatisfied_dependencies: [],
    dependency_target_options: [],
    attachments: [],
    summary: null,
    test_plan: null,
    pending_feedback: [],
    landing_queue_entry: null,
    workflows: [],
    workflows_pagination: {
      page: 1,
      per_page: 10,
      total_workflows: 0,
      total_pages: 1,
      first_item: 0,
      last_item: 0,
      previous_path: null,
      next_path: null
    },
    feature_flags: { terminal: false },
    actions: {
      can_start: false,
      can_poll_feedback: false,
      can_rebase: false,
      can_check_mergeability: false,
      can_retry: false,
      can_retry_from_failed_step: false,
      can_restart: false,
      can_cancel: false,
      can_approve: false,
      can_unapprove: false,
      can_reopen: false,
      can_mark_valid: false,
      can_claim: false,
      can_unclaim: false,
      can_override_dependencies: false,
      can_view_timeline: false,
      can_manage_tags: false,
      feedback_agent_options: [],
      rebase_agent_options: [],
      retry_agent_options: []
    },
    paths: {
      job_path: "/jobs/1",
      source_path: "/jobs/1/source",
      app_detail_path: "/api/v1/app/jobs/1",
      app_source_path: "/api/v1/app/jobs/1/source",
      app_timeline_path: "/api/v1/app/jobs/1/timeline",
      app_start_path: "/api/v1/app/jobs/1/start",
      app_run_again_path: "/api/v1/app/jobs/1/run_again",
      app_restart_path: "/api/v1/app/jobs/1/restart",
      app_cancel_path: "/api/v1/app/jobs/1/cancel",
      app_approve_path: "/api/v1/app/jobs/1/approve",
      app_unapprove_path: "/api/v1/app/jobs/1/unapprove",
      app_reopen_path: "/api/v1/app/jobs/1/reopen",
      app_poll_feedback_path: "/api/v1/app/jobs/1/poll_feedback",
      app_rebase_path: "/api/v1/app/jobs/1/rebase",
      app_check_mergeability_path: "/api/v1/app/jobs/1/check_mergeability",
      app_resume_path: "/api/v1/app/jobs/1/resume",
      app_tags_path: "/api/v1/app/jobs/1/tags",
      app_claim_path: "/api/v1/app/jobs/1/claim",
      app_dependencies_path: "/api/v1/app/jobs/1/dependencies",
      app_dependency_override_path: "/api/v1/app/jobs/1/dependencies/override",
      app_stack_base_path: "/api/v1/app/jobs/1/stack_base",
      app_mark_valid_path: "/api/v1/app/jobs/1/mark_valid",
      app_attachments_path: "/api/v1/app/jobs/1/attachments",
      app_pin_path: "/api/v1/app/jobs/1/pin",
      app_pending_feedback_path: "/api/v1/app/jobs/1/pending_feedback"
    },
    ...overrides
  }
}

function workflowPagination(totalWorkflows: number): JobDetailPayload["workflows_pagination"] {
  return {
    page: 1,
    per_page: 10,
    total_workflows: totalWorkflows,
    total_pages: 1,
    first_item: totalWorkflows > 0 ? 1 : 0,
    last_item: totalWorkflows,
    previous_path: null,
    next_path: null
  }
}

function baseJob(): JobDetailPayload["job"] {
  return {
    id: 1,
    kind: "direct",
    state: "running",
    summary_state: "running",
    priority: "medium",
    validity: "valid",
    credential_mode: "app",
    agent_provider: "codex",
    stack_base: "auto",
    issue_number: null,
    issue_url: null,
    issue_title: "Add origin chat link",
    issue_body: null,
    branch_name: "syrus/direct-1",
    pr_number: null,
    pr_url: null,
    external_pr_number: null,
    external_pr_url: null,
    pr_mergeable: null,
    pr_mergeable_checked_at: null,
    closure_reason: null,
    landing_failure_reason: null,
    retry_state: undefined,
    approved_at: null,
    approved_via: null,
    owner_user_id: null,
    owner_user: null,
    job_approvals: [],
    approval_status: null,
    claimed_at: null,
    claimed_by_user: null,
    claimed_by_current_user: false,
    total_cost_usd: null,
    billed_runs_count: 0,
    source_chat: null,
    workflows_count: 0,
    runs_count: 0,
    any_active_run: false,
    prepare_skipped: false,
    prepare_skip_reason: null,
    needs_attention: false,
    needs_attention_reason: null,
    needs_attention_since: null,
    grace_period_expires_at: null,
    created_at: null,
    updated_at: null,
    started_at: null,
    finished_at: null
  }
}

function jobSourcePayload(overrides: { withFile?: boolean; file?: NonNullable<JobSourcePayload["file"]> } = {}): JobSourcePayload {
  const file = overrides.file || (overrides.withFile ? { path: "app/models/user.rb", name: "user.rb", size: 15, language: "ruby", content: "class User\nend\n" } : null)

  return {
    job_id: 1,
    repository: { id: 2, slug: "acme/widgets", default_branch: "main", repository_path: "/repositories/2" },
    branch_name: "syrus/direct-1",
    default_ref: "main",
    selected_ref: "deadbeef12345678",
    selected_path: file?.path || null,
    merge_base_sha: "aabbccdd1234567",
    branch_commits: [
      { sha: "deadbeef12345678", short_sha: "deadbee", message: "Repair source browser", date: "2026-06-28T10:00:00Z" }
    ],
    tree_items: [
      { path: "app/models/user.rb", name: "user.rb", size: 512, language: "ruby" },
      { path: "README.md", name: "README.md", size: 128, language: "markdown" }
    ],
    tree_truncated: false,
    file,
    source_error: null,
    file_error: null,
    paths: {
      job_path: "/jobs/1",
      source_path: "/jobs/1/source",
      app_source_path: "/api/v1/app/jobs/1/source"
    }
  }
}

function workflow(overrides: Partial<JobWorkflow>): JobWorkflow {
  const id = overrides.id ?? 1
  return {
    id,
    slug: `WF-${id}`,
    path: `/workflows/${id}`,
    trigger_kind: "initial",
    agent_provider: "codex",
    state: "succeeded",
    failure_count: 0,
    artifacts: {},
    cleaned_up_at: null,
    retry_available: false,
    started_at: null,
    finished_at: null,
    created_at: null,
    updated_at: null,
    app_retry_step_path: `/workflows/${id}/retry`,
    app_push_commits_path: `/workflows/${id}/push_commits`,
    app_force_push_branch_path: `/workflows/${id}/force_push_branch`,
    app_discard_branch_output_path: `/workflows/${id}/discard_branch_output`,
    steps: [],
    ...overrides
  }
}

function step(overrides: Partial<JobStep>): JobStep {
  const id = overrides.id ?? 1
  return {
    id,
    kind: "implement",
    display_name: "Implement",
    display_status: "succeeded",
    position: 1,
    iteration: null,
    loop_id: null,
    state: "succeeded",
    started_at: null,
    finished_at: null,
    created_at: null,
    updated_at: null,
    details: null,
    latest: true,
    runs: [],
    ...overrides
  }
}

function run(overrides: Partial<JobRun>): JobRun {
  const id = overrides.id ?? 1
  return {
    id,
    state: "succeeded",
    trigger_kind: "initial",
    agent_provider: "codex",
    agent_outcome: "success",
    agent_turns: 1,
    agent_pr_title: null,
    agent_summary: null,
    parent_session_id: null,
    head_sha: null,
    iteration: null,
    started_at: null,
    last_heartbeat_at: null,
    finished_at: null,
    created_at: null,
    updated_at: null,
    cost_usd: null,
    input_tokens: null,
    output_tokens: null,
    agent_diff_present: false,
    agent_diff_bytes: 0,
    job_log_count: 0,
    rate_limited: false,
    failure_classification: null,
    run_diagnostic: null,
    health_snapshots: [],
    agent_session: null,
    can_stop: false,
    can_diagnose: false,
    can_resume: false,
    app_artifacts_path: `/api/v1/app/jobs/1/runs/${id}/artifacts`,
    app_stop_path: `/api/v1/app/jobs/1/runs/${id}/stop`,
    app_diagnose_path: `/api/v1/app/jobs/1/runs/${id}/diagnose`,
    app_resume_path: `/api/v1/app/jobs/1/runs/${id}/resume`,
    app_grade_log_path: null,
    ...overrides
  }
}

function jsonResponse(payload: unknown, init: ResponseInit = {}) {
  return new Response(JSON.stringify(payload), {
    status: init.status ?? 200,
    headers: { "Content-Type": "application/json", ...init.headers }
  })
}
