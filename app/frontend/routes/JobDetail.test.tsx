import { render, screen, within } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it } from "vitest"
import type { JobWorkflow } from "../api/jobs"
import { FeedbackHistoryPanel, TestPlanPanel } from "./JobDetail"

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
