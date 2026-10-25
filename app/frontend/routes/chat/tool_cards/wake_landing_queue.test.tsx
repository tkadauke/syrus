import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ChatPendingActionInline } from "../../../api/chats"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import wakeLandingQueueToolCard from "./wake_landing_queue"

const pending = { pending_action_id: 503, state: "pending", message: "Wake the landing queue?" }

function context(envelope: unknown, input?: Record<string, unknown>, livePendingAction: ChatPendingActionInline | null = null): ToolCardContext {
  return {
    toolName: normalizedToolName("mcp__syrus-chat-sidecar__wake_landing_queue"),
    input,
    resultBody: "",
    resultError: false,
    parsedResult: normalizedToolCardParsedResult(envelope),
    livePendingAction
  }
}

function liveAction(state: ChatPendingActionInline["state"], executionStatus?: string): ChatPendingActionInline {
  return {
    id: 503,
    action: "wake_landing_queue",
    state,
    label: "Wake landing queue",
    detail: null,
    execution_status: executionStatus,
    app_confirm_path: "/confirm",
    app_reject_path: "/reject"
  }
}

describe("wake_landing_queue tool card", () => {
  it.each([
    ["Claude text", { content: [{ type: "text", text: JSON.stringify(pending) }], structured_content: null }],
    ["Codex structured", { content: [], structured_content: pending }]
  ])("renders the Markdown input reason and pending outcome from a normalized %s envelope", (_label, envelope) => {
    const cardContext = context(envelope, { reason: "Retry after **repairing metadata**.\n\nSee https://example.com/run" })

    expect(cardContext.toolName).toBe("wake_landing_queue")
    expect(wakeLandingQueueToolCard.collapsedSummary?.(cardContext)).toBe("Wake landing queue · Pending")
    render(<>{wakeLandingQueueToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("Landing queue")).toBeInTheDocument()
    expect(screen.getByText("Outcome")).toBeInTheDocument()
    expect(screen.getAllByText("pending")).toHaveLength(2)
    expect(screen.getByText("repairing metadata").tagName).toBe("STRONG")
    expect(screen.getByRole("link", { name: "https://example.com/run" })).toHaveAttribute("href", "https://example.com/run")
  })

  it.each([
    ["confirmed action", liveAction("confirmed", "applied"), "Queued", "queued"],
    ["no-op wake", liveAction("confirmed", "noop"), "Queued", "queued"],
    ["rejected action", liveAction("rejected"), "Rejected", "rejected"]
  ])("shows the live outcome for a %s", (_label, live, summaryOutcome, renderedOutcome) => {
    const cardContext = context(pending, { reason: "Retry now." }, live)

    expect(wakeLandingQueueToolCard.collapsedSummary?.(cardContext)).toBe(`Wake landing queue · ${summaryOutcome}`)
    render(<>{wakeLandingQueueToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getAllByText(renderedOutcome)).not.toHaveLength(0)
    expect(screen.queryByText("pending")).not.toBeInTheDocument()
  })

  it("renders safely when recorded input is missing", () => {
    const cardContext = context(pending)

    expect(() => render(<>{wakeLandingQueueToolCard.renderExpanded(cardContext)}</>)).not.toThrow()
    expect(screen.getByText("Landing queue")).toBeInTheDocument()
    expect(screen.queryByText("Reason")).not.toBeInTheDocument()
  })

  it("falls back for malformed results", () => {
    expect(wakeLandingQueueToolCard.collapsedSummary?.(context({ content: [{ type: "text", text: "not json" }] }))).toBeNull()
    expect(wakeLandingQueueToolCard.renderExpanded(context({ structured_content: { unexpected: true } }))).toBeNull()
  })
})
