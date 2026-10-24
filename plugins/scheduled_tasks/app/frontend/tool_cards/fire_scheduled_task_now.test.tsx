import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ChatPendingActionInline } from "@app/api/chats"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult } from "@app/routes/chat/toolRendering"
import fireScheduledTaskNowToolCard, { examples } from "./fire_scheduled_task_now"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "fire_scheduled_task_now",
    input: { scheduled_task_id: 12 },
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const pendingAction = {
  pending_confirmation_id: 501,
  pending_action_id: 501,
  state: "pending",
  message: "Fire **TASK-12** immediately? See https://example.test/runbook."
}

function live(state: "confirmed" | "rejected" | "failed", overrides: Partial<ChatPendingActionInline> = {}): ChatPendingActionInline {
  return {
    id: 501,
    action: "fire_scheduled_task_now",
    state,
    label: "Fire scheduled task #12",
    detail: "scheduled_task_id: 12",
    app_confirm_path: "/confirm",
    app_reject_path: "/reject",
    ...overrides
  }
}

describe("fire_scheduled_task_now tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(fireScheduledTaskNowToolCard.toolName).toBe("fire_scheduled_task_now")
  })

  it("summarizes the collapsed row with the pending action id and state", () => {
    expect(fireScheduledTaskNowToolCard.collapsedSummary?.(context({ parsedResult: pendingAction }))).toBe("Fire now requested (#501, pending)")
  })

  it("renders every input and result field with linkified markdown", () => {
    render(<>{fireScheduledTaskNowToolCard.renderExpanded(context({ parsedResult: pendingAction }))}</>)

    expect(screen.getByText("Immediate fire requested")).toBeInTheDocument()
    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("TASK-12", { selector: "strong" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "https://example.test/runbook" })).toHaveAttribute("href", "https://example.test/runbook")
    expect(screen.getByText("ACTION-501")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "TASK-12" })).toHaveAttribute("href", "/scheduled_tasks/12")
    expect(screen.getByText("The task does not fire until the operator confirms.")).toBeInTheDocument()
  })

  it("renders without confirm or reject controls", () => {
    render(<>{fireScheduledTaskNowToolCard.renderExpanded(context({ parsedResult: pendingAction }))}</>)

    expect(screen.queryByRole("button", { name: /confirm/i })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /reject/i })).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Copy ACTION-501 to clipboard" })).toBeInTheDocument()
  })

  it("renders from pending_confirmation_id alone when pending_action_id is absent", () => {
    const parsedResult = { pending_confirmation_id: 777, state: "pending" }

    expect(fireScheduledTaskNowToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Fire now requested (#777, pending)")
  })

  it("defaults a result without a state to pending and shows the message empty state", () => {
    const parsedResult = { pending_action_id: 501, message: "" }

    render(<>{fireScheduledTaskNowToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("No confirmation message was provided.")).toBeInTheDocument()
  })

  it("offers Show more and a copyable full-message modal for long markdown", () => {
    const message = `Fire **TASK-12** after reviewing ${"the detailed runbook ".repeat(35)}`
    render(<>{fireScheduledTaskNowToolCard.renderExpanded(context({ parsedResult: { ...pendingAction, message } }))}</>)

    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    const dialog = screen.getByRole("dialog")
    expect(dialog).toHaveTextContent("the detailed runbook")
    expect(screen.getByRole("button", { name: "Copy Message to clipboard" })).toBeInTheDocument()
  })

  it("reflects confirmation and links the created Job from the live resource", () => {
    const livePendingAction = live("confirmed", { outcome: { fired: true, job_id: 884 }, resource_url: "/jobs/884", resource_title: "Scheduled run" })
    render(<>{fireScheduledTaskNowToolCard.renderExpanded(context({ parsedResult: pendingAction, livePendingAction }))}</>)

    expect(screen.getByText("confirmed")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-884" })).toHaveAttribute("href", "/jobs/884")
    expect(screen.getByText("The scheduled task was fired.")).toBeInTheDocument()
    expect(screen.queryByText(/does not fire until/)).not.toBeInTheDocument()
    expect(fireScheduledTaskNowToolCard.collapsedSummary?.(context({ parsedResult: pendingAction, livePendingAction }))).toBe("Scheduled task fired as JOB-884")
  })

  it("reads a created Job from differently shaped live outcomes", () => {
    const livePendingAction = live("confirmed", { outcome: { fired: true, job: { id: "885" } } })
    render(<>{fireScheduledTaskNowToolCard.renderExpanded(context({ parsedResult: pendingAction, livePendingAction }))}</>)
    expect(screen.getByRole("link", { name: "JOB-885" })).toHaveAttribute("href", "/jobs/885")
  })

  it("distinguishes a confirmed-but-skipped fire and shows its reason", () => {
    const livePendingAction = live("confirmed", { outcome: { fired: false, reason: "already_fired_window" } })
    render(<>{fireScheduledTaskNowToolCard.renderExpanded(context({ parsedResult: pendingAction, livePendingAction }))}</>)

    expect(screen.getByText("confirmed")).toBeInTheDocument()
    expect(screen.getByText("The scheduled task was not fired: already_fired_window.")).toBeInTheDocument()
    expect(screen.queryByText("The scheduled task was fired.")).not.toBeInTheDocument()
    expect(screen.queryByRole("link", { name: /^JOB-/ })).not.toBeInTheDocument()
    expect(fireScheduledTaskNowToolCard.collapsedSummary?.(context({ parsedResult: pendingAction, livePendingAction }))).toBe("Immediate fire skipped")
  })

  it("reflects rejection and failure details", () => {
    const rejected = live("rejected", { reason: "Operator changed course" })
    const { rerender } = render(<>{fireScheduledTaskNowToolCard.renderExpanded(context({ parsedResult: pendingAction, livePendingAction: rejected }))}</>)
    expect(screen.getByText("Operator changed course")).toBeInTheDocument()
    expect(screen.queryByText(/does not fire until/)).not.toBeInTheDocument()

    const failed = live("failed", { execution_error: "Task is archived" })
    rerender(<>{fireScheduledTaskNowToolCard.renderExpanded(context({ parsedResult: pendingAction, livePendingAction: failed }))}</>)
    expect(screen.getByText("Task is archived")).toBeInTheDocument()
    expect(fireScheduledTaskNowToolCard.collapsedSummary?.(context({ parsedResult: pendingAction, livePendingAction: failed }))).toBe("Immediate fire failed")
  })

  it("renders tool errors as a styled error card", () => {
    render(<>{fireScheduledTaskNowToolCard.renderExpanded(context({ resultError: true, resultBody: "scheduled task not found" }))}</>)
    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("scheduled task not found")).toBeInTheDocument()
  })

  it("renders a linked, meaningful empty state from the task input", () => {
    const emptyContext = context({ parsedResult: {} })
    render(<>{fireScheduledTaskNowToolCard.renderExpanded(emptyContext)}</>)

    expect(screen.getByText("empty")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "TASK-12" })).toHaveAttribute("href", "/scheduled_tasks/12")
    expect(screen.getByText("No immediate fire result was returned.")).toBeInTheDocument()
    expect(screen.queryByText(/^ACTION-/)).not.toBeInTheDocument()
    expect(fireScheduledTaskNowToolCard.collapsedSummary?.(emptyContext)).toBe("No immediate fire result for TASK-12")
  })

  it.each([
    ["structured content", { structured_content: pendingAction }],
    ["content text", { content: [{ type: "text", text: JSON.stringify(pendingAction) }] }]
  ])("accepts the %s provider envelope after shared normalization", (_label, envelope) => {
    const parsedResult = normalizedToolCardParsedResult(envelope)
    expect(fireScheduledTaskNowToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Fire now requested (#501, pending)")
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }

    expect(fireScheduledTaskNowToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(fireScheduledTaskNowToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"

    expect(fireScheduledTaskNowToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(fireScheduledTaskNowToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("publishes pending, confirmed, error, and empty catalog examples", () => {
    expect(examples.map((example) => example.id)).toEqual(["pending_markdown_message", "confirmed_with_job", "confirmed_but_skipped", "error", "empty"])
  })
})
