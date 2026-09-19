import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import type { ChatPendingActionInline } from "../../../api/chats"
import submitCodingChangesToolCard from "./submit_coding_changes"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "submit_coding_changes",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("submit_coding_changes tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(submitCodingChangesToolCard.toolName).toBe("submit_coding_changes")
  })

  it("summarizes the collapsed row with the tool's own message", () => {
    const context_ = context({
      input: { branch: "syrus/coding-322", title: "Add dark mode toggle", description: "Adds a toggle." },
      parsedResult: { pending_action_id: 88, state: "pending", message: "Submit coding changes is pending operator confirmation. Once confirmed, a Job will be created and the CodingHandoff workflow (graders, summarize, PR open) will be dispatched for branch 'syrus/coding-322'." }
    })
    expect(submitCodingChangesToolCard.collapsedSummary?.(context_)).toContain("pending operator confirmation")
  })

  it("renders branch, title, pending state, and message on success", () => {
    const context_ = context({
      input: { branch: "syrus/coding-322", title: "Add dark mode toggle", description: "Adds a toggle." },
      parsedResult: { pending_action_id: 88, state: "pending", message: "Submit coding changes is pending operator confirmation." }
    })
    render(<>{submitCodingChangesToolCard.renderExpanded(context_)}</>)

    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("#88")).toBeInTheDocument()
    expect(screen.getByText("Add dark mode toggle")).toBeInTheDocument()
    expect(screen.getByText("syrus/coding-322")).toBeInTheDocument()
    expect(screen.getByText("Submit coding changes is pending operator confirmation.")).toBeInTheDocument()
  })

  it("renders the auto-confirmed state distinctly", () => {
    const context_ = context({
      input: { branch: "syrus/coding-322", title: "Add dark mode toggle", description: "Adds a toggle." },
      parsedResult: { pending_action_id: 88, state: "confirming", message: "Submit coding changes was auto-confirmed by the active goal policy." }
    })
    render(<>{submitCodingChangesToolCard.renderExpanded(context_)}</>)

    expect(screen.getByText("confirming")).toBeInTheDocument()
    expect(screen.getByText("Submit coding changes was auto-confirmed by the active goal policy.")).toBeInTheDocument()
  })

  it("prefers the live pending action's state over the frozen tool-result state", () => {
    const live: ChatPendingActionInline = {
      id: 88,
      action: "submit_coding_changes",
      state: "confirmed",
      label: "Submit coding changes",
      detail: null,
      app_confirm_path: "/api/v1/app/chats/1/pending_actions/88/confirm",
      app_reject_path: "/api/v1/app/chats/1/pending_actions/88/reject"
    }
    const context_ = context({
      input: { branch: "syrus/coding-322", title: "Add dark mode toggle" },
      parsedResult: { pending_action_id: 88, state: "pending", message: "Submit coding changes is pending operator confirmation." },
      livePendingAction: live
    })
    render(<>{submitCodingChangesToolCard.renderExpanded(context_)}</>)

    expect(screen.getByText("confirmed")).toBeInTheDocument()
    expect(screen.queryByText("pending")).not.toBeInTheDocument()
  })

  it("ignores a live pending action for a different id", () => {
    const live: ChatPendingActionInline = {
      id: 99,
      action: "submit_coding_changes",
      state: "confirmed",
      label: "Submit coding changes",
      detail: null,
      app_confirm_path: "/api/v1/app/chats/1/pending_actions/99/confirm",
      app_reject_path: "/api/v1/app/chats/1/pending_actions/99/reject"
    }
    const context_ = context({
      input: { branch: "syrus/coding-322", title: "Add dark mode toggle" },
      parsedResult: { pending_action_id: 88, state: "pending", message: "Submit coding changes is pending operator confirmation." },
      livePendingAction: live
    })
    render(<>{submitCodingChangesToolCard.renderExpanded(context_)}</>)

    expect(screen.getByText("pending")).toBeInTheDocument()
  })

  it("omits branch/title rows when the tool call carried no input", () => {
    render(<>{submitCodingChangesToolCard.renderExpanded(context({ parsedResult: { pending_action_id: 88, state: "pending" } }))}</>)

    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.queryByText("Branch")).not.toBeInTheDocument()
    expect(screen.queryByText("Title")).not.toBeInTheDocument()
  })

  it("falls back to null for a malformed or error payload", () => {
    expect(submitCodingChangesToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(submitCodingChangesToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
    expect(submitCodingChangesToolCard.renderExpanded(context({ resultError: true, parsedResult: null, resultBody: "Error: title is required" }))).toBeNull()
  })
})
