import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import submitChatFeedbackToolCard from "./submit_chat_feedback"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "submit_chat_feedback",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("submit_chat_feedback tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(submitChatFeedbackToolCard.toolName).toBe("submit_chat_feedback")
  })

  it("summarizes the collapsed row with the tool's own message", () => {
    const context_ = context({
      input: { job_id: 4048, feedback: "Please fix the header." },
      parsedResult: { pending_confirmation_id: 501, pending_action_id: 501, state: "pending", message: "Chat feedback requires operator confirmation." }
    })
    expect(submitChatFeedbackToolCard.collapsedSummary?.(context_)).toBe("Chat feedback requires operator confirmation.")
  })

  it("renders target job, pending state, media refs, and a pending-confirmation note", () => {
    const context_ = context({
      input: { job_id: 4048, feedback: "Please fix the header.", media: [ "snapshot:42", "chat_image:7" ] },
      parsedResult: { pending_confirmation_id: 501, pending_action_id: 501, state: "pending", message: "Chat feedback requires operator confirmation." }
    })
    render(<>{submitChatFeedbackToolCard.renderExpanded(context_)}</>)

    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("JOB-4048")).toBeInTheDocument()
    expect(screen.getByText("#501")).toBeInTheDocument()
    expect(screen.getByText("Chat feedback requires operator confirmation.")).toBeInTheDocument()
    expect(screen.getByText("snapshot:42")).toBeInTheDocument()
    expect(screen.getByText("chat_image:7")).toBeInTheDocument()
    expect(screen.getByText("Confirming this will start a new chat_feedback workflow.")).toBeInTheDocument()
  })

  it("renders the queued state distinctly from the pending-confirmation state", () => {
    const context_ = context({
      input: { job_id: 4048, feedback: "Please fix the header." },
      parsedResult: { pending_confirmation_id: 501, pending_action_id: 501, state: "queued", status: "queued", message: "Feedback queued - will appear for your confirmation once JOB-4048 finishes its current run." }
    })
    render(<>{submitChatFeedbackToolCard.renderExpanded(context_)}</>)

    expect(screen.getByText("queued")).toBeInTheDocument()
    expect(screen.getByText(/chat_feedback workflow starts once it is confirmed/)).toBeInTheDocument()
  })

  it("omits the media section when no media was attached", () => {
    const context_ = context({
      input: { job_id: 4048, feedback: "Please fix the header." },
      parsedResult: { pending_action_id: 501, state: "pending", message: "Chat feedback requires operator confirmation." }
    })
    render(<>{submitChatFeedbackToolCard.renderExpanded(context_)}</>)

    expect(screen.queryByText("Media")).not.toBeInTheDocument()
  })

  it("falls back to null for a malformed or error payload", () => {
    expect(submitChatFeedbackToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(submitChatFeedbackToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
    expect(submitChatFeedbackToolCard.renderExpanded(context({ resultError: true, parsedResult: null, resultBody: "Error: feedback is required" }))).toBeNull()
  })
})
