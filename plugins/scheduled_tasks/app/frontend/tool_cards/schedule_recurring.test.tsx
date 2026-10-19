import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ChatPendingActionInline } from "@app/api/chats"
import type { ToolCardContext } from "@app/pluginToolCards"
import scheduleRecurringToolCard, { examples } from "./schedule_recurring"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "mcp__syrus-chat-sidecar__schedule_recurring",
    input: { label: "Weekly review", prompt: "Review **open work** and link JOB-42.", schedule_input: "Every Monday at 9:00 AM" },
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const proposal = {
  pending_confirmation_id: 501,
  schedule_explanation: "Runs every Monday at 9:00 AM UTC",
  cron_expression: "0 9 * * 1",
  next_fire_at: "2026-09-08T09:00:00Z"
}

function live(state: "confirmed" | "rejected", overrides: Partial<ChatPendingActionInline> = {}): ChatPendingActionInline {
  return {
    id: 501,
    action: "schedule_recurring",
    state,
    label: "Weekly review",
    detail: null,
    app_confirm_path: "/confirm",
    app_reject_path: "/reject",
    ...overrides
  }
}

describe("schedule_recurring tool card", () => {
  it("shows every proposed field with markdown, links, cron, and UTC interpretation", () => {
    render(<>{scheduleRecurringToolCard.renderExpanded(context({ parsedResult: proposal }))}</>)

    expect(screen.getByText("Weekly review")).toBeInTheDocument()
    expect(screen.getByText("open work").tagName).toBe("STRONG")
    expect(screen.getByTestId("markdown-preview-content")).toHaveTextContent("JOB-42")
    expect(screen.getByText("Every Monday at 9:00 AM")).toBeInTheDocument()
    expect(screen.getByText("0 9 * * 1")).toBeInTheDocument()
    expect(screen.getByText("Interpreted in UTC.")).toBeInTheDocument()
    expect(screen.getByText("ACTION-501")).toBeInTheDocument()
    expect(screen.getByText("Not created yet — awaiting operator confirmation.")).toBeInTheDocument()
  })

  it("reflects confirmation and links the created scheduled task", () => {
    const livePendingAction = live("confirmed", { resource_title: "Weekly review", resource_url: "/scheduled_tasks/77" })
    render(<>{scheduleRecurringToolCard.renderExpanded(context({ parsedResult: proposal, livePendingAction }))}</>)

    expect(screen.getByText("confirmed")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "TASK-77" })).toHaveAttribute("href", "/scheduled_tasks/77")
    expect(screen.queryByText(/Not created yet/)).not.toBeInTheDocument()
    expect(scheduleRecurringToolCard.collapsedSummary?.(context({ parsedResult: proposal, livePendingAction }))).toBe("Recurring task created: Weekly review")
  })

  it("reflects rejection and its reason", () => {
    const livePendingAction = live("rejected", { reason: "Operator changed course" })
    render(<>{scheduleRecurringToolCard.renderExpanded(context({ parsedResult: proposal, livePendingAction }))}</>)

    expect(screen.getByText("rejected")).toBeInTheDocument()
    expect(screen.getByText("Operator changed course")).toBeInTheDocument()
    expect(screen.queryByText(/Not created yet/)).not.toBeInTheDocument()
  })

  it("accepts the compatibility pending_action_id result shape", () => {
    const parsedResult = { ...proposal, pending_confirmation_id: undefined, pending_action_id: "502", state: "pending" }
    render(<>{scheduleRecurringToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("ACTION-502")).toBeInTheDocument()
  })

  it("renders result errors as a styled error card", () => {
    render(<>{scheduleRecurringToolCard.renderExpanded(context({ resultError: true, resultBody: "scheduled task not found" }))}</>)
    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("scheduled task not found")).toBeInTheDocument()
  })

  it("falls back for malformed and empty payloads and publishes catalog examples", () => {
    expect(scheduleRecurringToolCard.renderExpanded(context({ parsedResult: {} }))).toBeNull()
    expect(scheduleRecurringToolCard.renderExpanded(context({ parsedResult: null }))).toBeNull()
    expect(examples.map((example) => example.id)).toEqual(["pending_markdown_prompt", "write_access_error"])
  })
})
