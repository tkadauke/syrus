import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import type { ChatPendingActionInline } from "../../../api/chats"
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

function liveAction(overrides: Partial<ChatPendingActionInline> = {}): ChatPendingActionInline {
  return {
    id: 501,
    action: "submit_chat_feedback",
    state: "confirmed",
    label: "Submit feedback",
    detail: null,
    app_confirm_path: "/api/v1/app/chats/1/pending_actions/501/confirm",
    app_reject_path: "/api/v1/app/chats/1/pending_actions/501/reject",
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

  it("prefers the live pending action's state over the frozen tool-result state, and drops the forward-looking hint once resolved", () => {
    const context_ = context({
      input: { job_id: 4048, feedback: "Please fix the header." },
      parsedResult: { pending_confirmation_id: 501, pending_action_id: 501, state: "pending", message: "Chat feedback requires operator confirmation." },
      livePendingAction: liveAction({ state: "confirmed" })
    })
    render(<>{submitChatFeedbackToolCard.renderExpanded(context_)}</>)

    expect(screen.getByText("confirmed")).toBeInTheDocument()
    expect(screen.queryByText("pending")).not.toBeInTheDocument()
    expect(screen.queryByText("Confirming this will start a new chat_feedback workflow.")).not.toBeInTheDocument()
  })

  it("ignores a live pending action for a different id", () => {
    const context_ = context({
      input: { job_id: 4048, feedback: "Please fix the header." },
      parsedResult: { pending_confirmation_id: 501, pending_action_id: 501, state: "pending", message: "Chat feedback requires operator confirmation." },
      livePendingAction: liveAction({ id: 999, state: "confirmed" })
    })
    render(<>{submitChatFeedbackToolCard.renderExpanded(context_)}</>)

    expect(screen.getByText("pending")).toBeInTheDocument()
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
