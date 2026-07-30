import { jsonResponse } from "../testSupport"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter, useLocation } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { BootstrapPayload } from "../api/bootstrap"
import * as useTourModule from "../hooks/useTour"
import type { JobDetailPayload, JobRun, JobSourcePayload, JobStep, JobWorkflow } from "../api/jobs"
import { FeedbackHistoryPanel, JobDetailView, TestPlanPanel } from "./JobDetail"
import { StepAdversarialReviewPanel } from "./jobDetail/WorkflowGraph"

function buildBootstrap(seenTours: string[] = []): BootstrapPayload {
  return {
    current_user: {
      id: 1,
      email_address: "test@example.com",
      name: "Test User",
      first_name: null,
      last_name: null,
      display_name: "Test User",
      admin: false,
      role: "developer",
      scheduling_paused: false,
      landing_paused: false,
      agent_provider: "claude",
      chat_provider: null,
      agent_max_turns: 200,
      gemini_configured: false,
      theme: "light",
      locale: "en",
      seen_tours: seenTours
    },
    team_user_count: 1,
    app: {
      revision: "abc123",
      revision_url: null,
      version: null,
      built_at: null,
      bug_report_mode: null,
      report_issue_repo_slug: "owner/repo"
    },
    setup_status: null,
    public: {
      first_signup: false,
      signups_open: false,
      signup_path: "/session/new",
      sign_in_path: "/session/new",
      docs_url: "https://docs.example.com",
      evaluation_url: "https://example.com"
    },
    unread_notifications_count: 0,
    csrf_token: "test-token",
    feature_flags: {}
  }
}

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

  it("skips workflows with null artifacts when rendering coverage", () => {
    renderJobDetail(jobPayload({
      workflows: [
        workflow({ id: 1, artifacts: { coverage: { summary: { lines_pct: 92.4, branches_pct: null, functions_pct: null } } } }),
        workflow({ id: 2, artifacts: null })
      ],
      workflows_pagination: workflowPagination(2)
    }))

    expect(screen.getByTestId("coverage-card")).toBeInTheDocument()
    expect(screen.getByText("92.4%")).toBeInTheDocument()
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

  it("shows the waiting banner when a queued job is blocked by unhealthy main branch", () => {
    renderJobDetail(jobPayload({
      job: { ...baseJob(), state: "queued", main_branch_repair: false },
      repository: {
        id: 2, slug: "acme/widgets", owner: "acme", name: "widgets", default_branch: "main",
        review_policy: "self", feedback_policy: "confirm", repository_path: "/repositories/2",
        main_health: "broken", landing_paused: true
      }
    }))

    expect(screen.getByText("This job is waiting for repository health to recover.")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "View repository health" })).toBeInTheDocument()
  })

  it("shows the repair banner for a main branch repair job instead of the waiting banner", () => {
    renderJobDetail(jobPayload({
      job: { ...baseJob(), state: "queued", main_branch_repair: true },
      repository: {
        id: 2, slug: "acme/widgets", owner: "acme", name: "widgets", default_branch: "main",
        review_policy: "self", feedback_policy: "confirm", repository_path: "/repositories/2",
        main_health: "broken", landing_paused: true
      }
    }))

    expect(screen.getByText("This job is fixing the broken main branch.")).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "View repository health" })).not.toBeInTheDocument()
  })

  it("opens the overflow menu aligned to the right-0 edge when the menu fits within the scroll container", () => {
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

  it("opens the overflow menu aligned to the left-0 edge when a left-open menu would be clipped", () => {
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

  it("opens the overflow menu to the right when the scroll container's boundary would clip a left-open menu", () => {
    renderJobDetail(jobPayload())
    const menuButton = screen.getByRole("button", { name: "⋯" })

    vi.spyOn(menuButton, "getBoundingClientRect").mockReturnValue({
      right: 280, left: 240, top: 0, bottom: 36, width: 40, height: 36, x: 240, y: 0, toJSON: () => ({})
    } as DOMRect)

    const parentEl = menuButton.parentElement!
    const savedGetComputedStyle = window.getComputedStyle.bind(window)
    vi.spyOn(window, "getComputedStyle").mockImplementation((el, pseudo) => {
      const original = savedGetComputedStyle(el, pseudo)
      if (el === parentEl) {
        return new Proxy(original, {
          get(target, key: string | symbol) {
            if (key === "overflowX") return "auto"
            const val = Reflect.get(target, key)
            return typeof val === "function" ? (val as CallableFunction).bind(target) : val
          }
        })
      }
      return original
    })
    vi.spyOn(parentEl, "getBoundingClientRect").mockReturnValue({
      left: 200, right: 1000, top: 0, bottom: 800, width: 800, height: 800, x: 200, y: 0, toJSON: () => ({})
    } as DOMRect)

    fireEvent.click(menuButton)

    // button.right - 224 = 280 - 224 = 56 < containerLeft (200), so opens right
    const menu = screen.getByRole("menu")
    expect(menu).toHaveClass("left-0")
    expect(menu).not.toHaveClass("right-0")
  })

  it("renders dependency blockers as copyable Job slugs with status pills", () => {
    const parsedDependency = {
      id: 12,
      source: "parsed",
      manual: false,
      pending: false,
      succeeded: false,
      unresolved_slug: null,
      depends_on_epic: null,
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
      depends_on_epic: null,
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
    expect(screen.getAllByRole("button", { name: "Copy JOB-1101 to clipboard" })).toHaveLength(2)
    expect(screen.getAllByRole("button", { name: "Copy JOB-1108 to clipboard" })).toHaveLength(2)
    expect(screen.getAllByText("queued").length).toBeGreaterThanOrEqual(4)
    expect(screen.queryByText(/tkadauke\/syrus JOB-1101/)).not.toBeInTheDocument()
    expect(screen.queryByText("tkadauke/syrus #1101 (queued)")).not.toBeInTheDocument()
  })

  it("renders epic dependency rows with a link to the epic and a remove button", () => {
    const epicDependency = {
      id: 20,
      source: "manual",
      manual: true,
      pending: false,
      succeeded: false,
      unresolved_slug: null,
      depends_on_job: null,
      depends_on_epic: {
        id: 5,
        number: 155,
        slug: "EPIC-155",
        title: "Platform migration",
        state: "in_progress",
        repository_slug: "tkadauke/syrus",
        display_number: "EPIC-155",
        epic_path: "/epics/EPIC-155"
      }
    }

    renderJobDetail(jobPayload({
      dependencies: [ epicDependency ],
      unsatisfied_dependencies: [ epicDependency ],
      epic_dependency_target_options: []
    }))

    expect(screen.getByText("Blocked on:")).toBeInTheDocument()
    const epicLink = screen.getAllByRole("link", { name: /EPIC-155 — Platform migration/ })[0]
    expect(epicLink).toHaveAttribute("href", "/app-shell/epics/EPIC-155")
    expect(screen.getByRole("button", { name: "Remove" })).toBeInTheDocument()
    expect(screen.getByText("Not yet satisfied")).toBeInTheDocument()
  })

  it("shows the add epic dependency picker when epics are available", () => {
    renderJobDetail(jobPayload({
      epic_dependency_target_options: [
        { label: "EPIC-10 — Widget redesign", value: 10 },
        { label: "EPIC-11 — API overhaul", value: 11 }
      ]
    }))

    fireEvent.click(screen.getByRole("button", { name: "+ Add epic dependency" }))

    expect(screen.getByPlaceholderText("Type to search...")).toBeInTheDocument()
    expect(screen.getByText("EPIC-10 — Widget redesign")).toBeInTheDocument()
    expect(screen.getByText("EPIC-11 — API overhaul")).toBeInTheDocument()
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
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({ workflow: { id: 2, trigger_kind: "chat_feedback" } }, 201))
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
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({ error: { message: "Job already has active feedback." } }, 422))
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

  it("shows a Summary button in the run row for summarize steps and renders summary as markdown", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      job_id: 1, run_id: 30, agent_diff: null, agent_diff_bytes: 0, logs_count: 1,
      logs: [{ id: 1, sequence: 1, kind: "assistant", chunk: "done", created_at: "2026-07-01T10:00:00Z" }]
    }))

    renderJobDetail(jobPayload({
      workflows: [
        workflow({
          id: 5,
          artifacts: { summary: "## Key changes\n\nFixed **all the bugs**." },
          steps: [
            step({ id: 10, kind: "summarize", display_name: "Summarize", runs: [ run({ id: 30, job_log_count: 1 }) ] })
          ]
        })
      ],
      workflows_pagination: workflowPagination(1)
    }), { activeTab: "workflows" })

    fireEvent.click(screen.getByRole("button", { name: /Summarize/ }))

    const runCard = screen.getByText(/Run #30/).closest("div.rounded")!
    const buttons = within(runCard as HTMLElement).getAllByRole("button")
    const buttonLabels = buttons.map((b) => b.textContent)
    expect(buttonLabels).toContain("Transcript")
    expect(buttonLabels).toContain("Summary")
    expect(buttonLabels.indexOf("Summary")).toBeGreaterThan(buttonLabels.indexOf("Transcript"))

    fireEvent.click(within(runCard as HTMLElement).getByRole("button", { name: "Summary" }))

    expect(await screen.findByRole("heading", { name: "Summary" })).toBeInTheDocument()
    expect(screen.getByRole("heading", { name: "Key changes" })).toBeInTheDocument()
    expect(document.querySelector("strong")).toHaveTextContent("all the bugs")
  })

  it("renders run agent_summary as markdown in the run row", () => {
    renderJobDetail(jobPayload({
      workflows: [
        workflow({
          id: 7,
          steps: [
            step({ id: 12, kind: "implement", display_name: "Implement", runs: [
              run({ id: 32, agent_summary: "## Result\n\nFixed **the bug**." })
            ] })
          ]
        })
      ],
      workflows_pagination: workflowPagination(1)
    }), { activeTab: "workflows" })

    fireEvent.click(screen.getByRole("button", { name: /Implement/ }))

    expect(screen.getByRole("heading", { name: "Result" })).toBeInTheDocument()
    expect(document.querySelector("strong")).toHaveTextContent("the bug")
  })

  it("renders agent summary as markdown in the Summary tab", () => {
    renderJobDetail(jobPayload({
      summary: { run_id: 1, text: "## Summary\n\nFixed **the bug**.", finished_at: null }
    }))

    expect(screen.getByRole("heading", { name: "Summary" })).toBeInTheDocument()
    expect(document.querySelector("strong")).toHaveTextContent("the bug")
  })

  it("shows a Test Plan button in the run row for test_plan steps", () => {
    renderJobDetail(jobPayload({
      workflows: [
        workflow({
          id: 6,
          artifacts: { test_plan: { steps: ["Run bin/rspec", "Run bin/test-react"], notes: null } },
          steps: [
            step({ id: 11, kind: "test_plan", display_name: "Test plan", runs: [ run({ id: 31, job_log_count: 1 }) ] })
          ]
        })
      ],
      workflows_pagination: workflowPagination(1)
    }), { activeTab: "workflows" })

    fireEvent.click(screen.getByRole("button", { name: /Test plan/ }))

    const runCard = screen.getByText(/Run #31/).closest("div.rounded")!
    const buttons = within(runCard as HTMLElement).getAllByRole("button")
    const buttonLabels = buttons.map((b) => b.textContent)
    expect(buttonLabels).toContain("Transcript")
    expect(buttonLabels).toContain("Test Plan")
    expect(buttonLabels.indexOf("Test Plan")).toBeGreaterThan(buttonLabels.indexOf("Transcript"))

    fireEvent.click(within(runCard as HTMLElement).getByRole("button", { name: "Test Plan" }))

    expect(screen.getByRole("heading", { name: "Test plan" })).toBeInTheDocument()
    const items = screen.getAllByRole("listitem")
    expect(items.map((i) => i.textContent)).toEqual(["Run bin/rspec", "Run bin/test-react"])
  })

  it("renders test plan notes as markdown in the step panel", () => {
    renderJobDetail(jobPayload({
      workflows: [
        workflow({
          id: 8,
          artifacts: { test_plan: { steps: [], notes: "Run `bin/rspec` and verify **all** pass." } },
          steps: [
            step({ id: 13, kind: "test_plan", display_name: "Test plan", runs: [ run({ id: 33, job_log_count: 0 }) ] })
          ]
        })
      ],
      workflows_pagination: workflowPagination(1)
    }), { activeTab: "workflows" })

    fireEvent.click(screen.getByRole("button", { name: /Test plan/ }))
    fireEvent.click(within(screen.getByText(/Run #33/).closest("div.rounded")! as HTMLElement).getByRole("button", { name: "Test Plan" }))

    expect(screen.getByText("bin/rspec").tagName).toBe("CODE")
    expect(screen.getByText("all").tagName).toBe("STRONG")
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

  it("renders notes as markdown", () => {
    render(
      <TestPlanPanel
        testPlan={{
          workflow_id: 5,
          steps: [],
          notes: "Run `bin/rspec` and verify **all** pass."
        }}
      />
    )

    expect(screen.getByText("bin/rspec").tagName).toBe("CODE")
    expect(screen.getByText("all").tagName).toBe("STRONG")
  })

  it("renders nothing when no test plan is available", () => {
    render(<TestPlanPanel testPlan={null} />)

    expect(screen.queryByRole("heading", { name: "Test plan" })).not.toBeInTheDocument()
  })
})

describe("StepAdversarialReviewPanel", () => {
  it("renders critique as markdown", () => {
    render(
      <StepAdversarialReviewPanel
        iterations={[{ iteration: 1, verdict: "approved", critique: "**Great** work with `clean` code." }]}
        onClose={() => {}}
      />
    )

    expect(screen.getByText("Great").tagName).toBe("STRONG")
    expect(screen.getByText("clean").tagName).toBe("CODE")
  })

  it("shows approved verdict badge on the final iteration", () => {
    render(
      <StepAdversarialReviewPanel
        iterations={[{ iteration: 1, verdict: "approved", critique: "Looks good." }]}
        onClose={() => {}}
      />
    )

    expect(screen.getByText("Approved")).toBeInTheDocument()
  })

  it("shows needs-work verdict badge on the final iteration", () => {
    render(
      <StepAdversarialReviewPanel
        iterations={[{ iteration: 1, verdict: "needs_work", critique: "Fix the tests." }]}
        onClose={() => {}}
      />
    )

    expect(screen.getByText("Needs work")).toBeInTheDocument()
  })

  it("renders multiple rounds with round labels", () => {
    render(
      <StepAdversarialReviewPanel
        iterations={[
          { iteration: 1, verdict: "needs_work", critique: "Not yet." },
          { iteration: 2, verdict: "approved", critique: "Now it is." }
        ]}
        onClose={() => {}}
      />
    )

    expect(screen.getByText("Round 1")).toBeInTheDocument()
    expect(screen.getByText("Round 2")).toBeInTheDocument()
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
    expect(screen.getByText(/Please tighten the dashboard copy/)).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "WF-2" })).toHaveAttribute("href", "/app-shell/workflows/2")
  })

  it("renders markdown syntax in chat feedback text", () => {
    renderFeedbackHistory([
      workflow({
        id: 7,
        trigger_kind: "chat_feedback",
        created_at: "2026-06-02T10:00:00Z",
        artifacts: { chat_feedback: "Please **tighten** the copy.\n- Keep it short\n- Be direct" }
      })
    ])

    expect(screen.getByText("tighten").tagName).toBe("STRONG")
    expect(screen.getByText("Keep it short")).toBeInTheDocument()
    expect(screen.getByText("Be direct")).toBeInTheDocument()
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

describe("PrioritySelector", () => {
  it("renders a select with the current priority selected", () => {
    renderJobDetail(jobPayload({ job: { ...baseJob(), priority: "high" } }))

    const select = screen.getByRole("combobox", { name: "Priority" })
    expect(select).toHaveValue("high")
  })

  it("changes priority without a dialog for non-urgent values", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      jsonResponse(jobPayload({ job: { ...baseJob(), priority: "low" } }))
    )
    renderJobDetail(jobPayload({ job: { ...baseJob(), priority: "medium" } }))

    fireEvent.change(screen.getByRole("combobox", { name: "Priority" }), { target: { value: "low" } })

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/jobs/1/priority",
        expect.objectContaining({ method: "PATCH", body: JSON.stringify({ priority: "low" }) })
      )
    })
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
  })

  it("shows the urgent confirmation dialog when urgent is selected", () => {
    renderJobDetail(jobPayload({ job: { ...baseJob(), priority: "high" } }))

    fireEvent.change(screen.getByRole("combobox", { name: "Priority" }), { target: { value: "urgent" } })

    expect(screen.getByRole("dialog")).toBeInTheDocument()
    expect(screen.getByText(/pause all other jobs in this repository/)).toBeInTheDocument()
  })

  it("does not call the endpoint when the urgent dialog is cancelled", async () => {
    const fetchSpy = vi.spyOn(window, "fetch")
    renderJobDetail(jobPayload({ job: { ...baseJob(), priority: "high" } }))

    fireEvent.change(screen.getByRole("combobox", { name: "Priority" }), { target: { value: "urgent" } })
    fireEvent.click(screen.getByRole("button", { name: "Cancel" }))

    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
    expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/jobs/1/priority", expect.anything())
  })

  it("calls the priority endpoint when the urgent dialog is confirmed", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      jsonResponse(jobPayload({ job: { ...baseJob(), priority: "urgent" } }))
    )
    renderJobDetail(jobPayload({ job: { ...baseJob(), priority: "high" } }))

    fireEvent.change(screen.getByRole("combobox", { name: "Priority" }), { target: { value: "urgent" } })
    fireEvent.click(screen.getByRole("button", { name: "Confirm" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/jobs/1/priority",
        expect.objectContaining({ method: "PATCH", body: JSON.stringify({ priority: "urgent" }) })
      )
    })
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
  })

  it("closes the urgent dialog when Escape is pressed", () => {
    renderJobDetail(jobPayload({ job: { ...baseJob(), priority: "medium" } }))

    fireEvent.change(screen.getByRole("combobox", { name: "Priority" }), { target: { value: "urgent" } })
    expect(screen.getByRole("dialog")).toBeInTheDocument()

    fireEvent.keyDown(document, { key: "Escape" })
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
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

describe("Job detail tour", () => {
  afterEach(() => vi.restoreAllMocks())

  function renderWithBootstrap(seenTours: string[] = []) {
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity } } })
    queryClient.setQueryData(["bootstrap"], buildBootstrap(seenTours))
    return render(
      <QueryClientProvider client={queryClient}>
        <MemoryRouter initialEntries={["/app-shell/jobs/1"]}>
          <JobDetailView
            activeTab="summary"
            onSelectTab={() => {}}
            payload={jobPayload()}
            prefix="/app-shell"
            queryKey={["jobs", "1", "detail", ""]}
          />
        </MemoryRouter>
      </QueryClientProvider>
    )
  }

  it("uses the job_detail tour id", () => {
    vi.spyOn(useTourModule, "useTour").mockReturnValue({ run: false, handleJoyrideCallback: vi.fn() })
    renderJobDetail(jobPayload())
    expect(useTourModule.useTour).toHaveBeenCalledWith("job_detail")
  })

  it("run is true when job_detail has not been seen", () => {
    const spy = vi.spyOn(useTourModule, "useTour")
    renderWithBootstrap([])
    expect(spy).toHaveReturnedWith(expect.objectContaining({ run: true }))
  })

  it("run is false when job_detail has already been seen", () => {
    const spy = vi.spyOn(useTourModule, "useTour")
    renderWithBootstrap(["job_detail"])
    expect(spy).toHaveReturnedWith(expect.objectContaining({ run: false }))
  })

  it("renders the timeline tour target when the timeline is visible", () => {
    vi.spyOn(useTourModule, "useTour").mockReturnValue({ run: false, handleJoyrideCallback: vi.fn() })
    const p = jobPayload()
    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/1"]}>
          <JobDetailView
            activeTab="summary"
            onSelectTab={() => {}}
            payload={{ ...p, actions: { ...p.actions, can_view_timeline: true } }}
            prefix="/app-shell"
            queryKey={["jobs", "1", "detail", ""]}
          />
        </MemoryRouter>
      </QueryClientProvider>
    )
    expect(document.querySelector("[data-tour='job-timeline']")).toBeInTheDocument()
  })

  it("renders the header actions tour target", () => {
    vi.spyOn(useTourModule, "useTour").mockReturnValue({ run: false, handleJoyrideCallback: vi.fn() })
    renderJobDetail(jobPayload())
    expect(document.querySelector("[data-tour='job-approve']")).toBeInTheDocument()
  })

  it("renders the details section tour target", () => {
    vi.spyOn(useTourModule, "useTour").mockReturnValue({ run: false, handleJoyrideCallback: vi.fn() })
    renderJobDetail(jobPayload())
    expect(document.querySelector("[data-tour='job-pr-link']")).toBeInTheDocument()
  })

  it("renders the feedback tour target when job is in implemented state", () => {
    vi.spyOn(useTourModule, "useTour").mockReturnValue({ run: false, handleJoyrideCallback: vi.fn() })
    renderJobDetail(jobPayload({ job: { ...baseJob(), state: "implemented", summary_state: "implemented" } }))
    expect(document.querySelector("[data-tour='job-feedback']")).toBeInTheDocument()
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
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity } } })
  queryClient.setQueryData(["bootstrap"], buildBootstrap(["job_detail"]))

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
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity } } })
  queryClient.setQueryData(["bootstrap"], buildBootstrap(["job_detail"]))

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
      repository_path: "/repositories/2",
      main_health: "unknown",
      landing_paused: false
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
    epic_dependency_target_options: [],
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
      can_open_in_coding_mode: false,
      can_open_in_local_mode: false,
      can_cancel_local_mode: false,
      linked_chat_id: null,
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
      app_epic_dependencies_path: "/api/v1/app/jobs/1/epic_dependencies",
      app_stack_base_path: "/api/v1/app/jobs/1/stack_base",
      app_mark_valid_path: "/api/v1/app/jobs/1/mark_valid",
      app_attachments_path: "/api/v1/app/jobs/1/attachments",
      app_pin_path: "/api/v1/app/jobs/1/pin",
      app_pending_feedback_path: "/api/v1/app/jobs/1/pending_feedback",
      app_open_in_coding_mode_path: "/api/v1/app/jobs/1/open_in_coding_mode",
      app_open_in_local_mode_path: "/api/v1/app/jobs/1/open_in_local_mode",
      app_cancel_local_mode_path: "/api/v1/app/jobs/1/cancel_local_mode",
      app_priority_path: "/api/v1/app/jobs/1/priority"
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
    main_branch_repair: false,
    created_at: null,
    updated_at: null,
    started_at: null,
    finished_at: null,
    start_blocked_reason: null,
    start_blocked_at: null
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
    step_agent_diff_present: false,
    step_agent_diff_bytes: 0,
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
