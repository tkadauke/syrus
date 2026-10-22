import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ChatPendingActionInline } from "../../../api/chats"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import pauseLandingQueueToolCard from "./pause_landing_queue"

const pending = { pending_action_id: 501, pending_confirmation_id: 501, state: "pending", message: "Pause the landing queue?" }

function context(envelope: unknown, livePendingAction: ChatPendingActionInline | null = null): ToolCardContext {
  return {
    toolName: normalizedToolName("mcp__syrus-chat-sidecar__pause_landing_queue"),
    resultBody: "",
    resultError: false,
    parsedResult: normalizedToolCardParsedResult(envelope),
    livePendingAction
  }
}

function liveAction(state: ChatPendingActionInline["state"], executionStatus?: string): ChatPendingActionInline {
  return {
    id: 501,
    action: "pause_landing_queue",
    state,
    label: "Pause landing queue",
    detail: null,
    execution_status: executionStatus,
    app_confirm_path: "/confirm",
    app_reject_path: "/reject"
  }
}

describe("pause_landing_queue tool card", () => {
  it.each([
    ["Claude text", { content: [{ type: "text", text: JSON.stringify(pending) }], structured_content: null }],
    ["Codex structured", { content: [], structured_content: pending }]
  ])("renders the queue target and pending outcome from a normalized %s envelope", (_label, envelope) => {
    const cardContext = context(envelope)

    expect(cardContext.toolName).toBe("pause_landing_queue")
    expect(pauseLandingQueueToolCard.collapsedSummary?.(cardContext)).toBe("Pause landing queue · Pending")
    render(<>{pauseLandingQueueToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("Target")).toBeInTheDocument()
    expect(screen.getByText("Landing queue")).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "Landing queue" })).not.toBeInTheDocument()
    expect(screen.getByText("Outcome")).toBeInTheDocument()
    expect(screen.getAllByText("pending")).toHaveLength(2)
  })

  it.each([
    ["confirmed action", liveAction("confirmed", "applied"), "Paused", "paused"],
    ["rejected action", liveAction("rejected"), "Rejected", "rejected"]
  ])("shows the live outcome for a %s", (_label, live, summaryOutcome, renderedOutcome) => {
    const cardContext = context(pending, live)

    expect(pauseLandingQueueToolCard.collapsedSummary?.(cardContext)).toBe(`Pause landing queue · ${summaryOutcome}`)
    render(<>{pauseLandingQueueToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getAllByText(renderedOutcome)).not.toHaveLength(0)
    expect(screen.queryByText("pending")).not.toBeInTheDocument()
  })

  it("falls back for malformed results", () => {
    expect(pauseLandingQueueToolCard.collapsedSummary?.(context({ content: [{ type: "text", text: "not json" }] }))).toBeNull()
    expect(pauseLandingQueueToolCard.renderExpanded(context({ structured_content: { unexpected: true } }))).toBeNull()
  })
})
