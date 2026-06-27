import { render, screen, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it } from "vitest"
import type { JobDetailPayload, JobWorkflow } from "../api/jobs"
import { FeedbackHistoryPanel, JobDetailView, TestPlanPanel } from "./JobDetail"

describe("JobDetailView", () => {
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

  it("renders the empty state when no test plan is available", () => {
    render(<TestPlanPanel testPlan={null} />)

    expect(screen.getByRole("heading", { name: "Test plan" })).toBeInTheDocument()
    expect(screen.getByText("No test plan yet.")).toBeInTheDocument()
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

function renderFeedbackHistory(workflows: JobWorkflow[]) {
  return render(
    <MemoryRouter>
      <FeedbackHistoryPanel prefix="/app-shell" workflows={workflows} />
    </MemoryRouter>
  )
}

function renderJobDetail(payload: JobDetailPayload) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })

  return render(
    <QueryClientProvider client={queryClient}>
      <MemoryRouter initialEntries={["/app-shell/jobs/1"]}>
        <JobDetailView
          activeTab="summary"
          onSelectTab={() => {}}
          payload={payload}
          prefix="/app-shell"
          queryKey={["jobs", "1", "detail", ""]}
        />
      </MemoryRouter>
    </QueryClientProvider>
  )
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
      repository_path: "/repositories/2"
    },
    epic: null,
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
      app_pin_path: "/api/v1/app/jobs/1/pin"
    },
    ...overrides
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
    created_at: null,
    updated_at: null,
    started_at: null,
    finished_at: null
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
    steps: [],
    ...overrides
  }
}
