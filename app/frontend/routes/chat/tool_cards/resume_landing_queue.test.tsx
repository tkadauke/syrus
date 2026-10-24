import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ChatPendingActionInline } from "../../../api/chats"
import { toolCardContextForExample, type ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import resumeLandingQueueToolCard, { examples } from "./resume_landing_queue"

const pending = { pending_action_id: 502, pending_confirmation_id: 502, state: "pending", message: "Resume the landing queue?" }

function context(envelope: unknown, livePendingAction: ChatPendingActionInline | null = null): ToolCardContext {
  return {
    toolName: normalizedToolName("mcp__syrus-chat-sidecar__resume_landing_queue"),
    resultBody: "",
    resultError: false,
    parsedResult: normalizedToolCardParsedResult(envelope),
    livePendingAction
  }
}

function liveAction(state: ChatPendingActionInline["state"], executionStatus?: string): ChatPendingActionInline {
  return {
    id: 502,
    action: "resume_landing_queue",
    state,
    label: "Resume landing queue",
    detail: null,
    execution_status: executionStatus,
    app_confirm_path: "/confirm",
    app_reject_path: "/reject"
  }
}

describe("resume_landing_queue tool card", () => {
  it("registers pending, resumed, and rejected catalog fixtures", () => {
    expect(examples.map((example) => example.id)).toEqual(["pending_confirmation", "resumed", "rejected"])
  })

  it.each([
    ["pending_confirmation", "pending"],
    ["resumed", "resumed"],
    ["rejected", "rejected"]
  ])("renders the %s catalog fixture", (id, outcome) => {
    const example = examples.find((candidate) => candidate.id === id)
    if (!example) throw new Error(`missing fixture: ${id}`)
    render(<>{resumeLandingQueueToolCard.renderExpanded(toolCardContextForExample(resumeLandingQueueToolCard.toolName, example))}</>)
    expect(screen.getByText("Landing queue")).toBeInTheDocument()
    expect(screen.getAllByText(outcome)).not.toHaveLength(0)
  })

  it.each([
    ["Claude text", { content: [{ type: "text", text: JSON.stringify(pending) }], structured_content: null }],
    ["Codex structured", { content: [], structured_content: pending }]
  ])("renders the queue target and pending outcome from a normalized %s envelope", (_label, envelope) => {
    const cardContext = context(envelope)
    expect(cardContext.toolName).toBe("resume_landing_queue")
    expect(resumeLandingQueueToolCard.collapsedSummary?.(cardContext)).toBe("Resume landing queue · Pending")
    render(<>{resumeLandingQueueToolCard.renderExpanded(cardContext)}</>)
    expect(screen.getByText("Target")).toBeInTheDocument()
    expect(screen.getByText("Landing queue")).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "Landing queue" })).not.toBeInTheDocument()
    expect(screen.getByText("Outcome")).toBeInTheDocument()
    expect(screen.getAllByText("pending")).toHaveLength(2)
  })

  it.each([
    ["confirmed action", liveAction("confirmed", "applied"), "Resumed", "resumed"],
    ["rejected action", liveAction("rejected"), "Rejected", "rejected"]
  ])("shows the live outcome for a %s", (_label, live, summaryOutcome, renderedOutcome) => {
    const cardContext = context(pending, live)
    expect(resumeLandingQueueToolCard.collapsedSummary?.(cardContext)).toBe(`Resume landing queue · ${summaryOutcome}`)
    render(<>{resumeLandingQueueToolCard.renderExpanded(cardContext)}</>)
    expect(screen.getAllByText(renderedOutcome)).not.toHaveLength(0)
    expect(screen.queryByText("pending")).not.toBeInTheDocument()
  })

  it("falls back for malformed results", () => {
    expect(resumeLandingQueueToolCard.collapsedSummary?.(context({ content: [{ type: "text", text: "not json" }] }))).toBeNull()
    expect(resumeLandingQueueToolCard.renderExpanded(context({ structured_content: { unexpected: true } }))).toBeNull()
  })
})
