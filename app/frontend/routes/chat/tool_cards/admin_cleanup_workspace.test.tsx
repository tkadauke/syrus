import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ChatPendingActionInline } from "@app/api/chats"
import type { ToolCardContext } from "@app/pluginToolCards"
import { redactToolCardValue } from "@app/toolCardSecurity"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import adminCleanupWorkspaceToolCard, { examples } from "./admin_cleanup_workspace"

const payload = {
  pending_action_id: 501,
  pending_confirmation_id: 501,
  state: "pending",
  reason: "Cleanup was requested by **operations**.",
  message: "Clean workspace for workflow #61288?"
}

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "admin_cleanup_workspace",
    resultBody: "",
    resultError: false,
    parsedResult: payload,
    input: { workflow_id: 61288, reason: "Remove the **completed** workspace." },
    ...overrides
  }
}

function liveAction(state: "confirmed" | "rejected", reason?: string): ChatPendingActionInline {
  return {
    id: 501,
    action: "admin_cleanup_workspace",
    state,
    reason,
    label: "Clean workflow workspace",
    detail: null,
    app_confirm_path: "/api/v1/app/chats/1/pending_actions/501/confirm",
    app_reject_path: "/api/v1/app/chats/1/pending_actions/501/reject"
  }
}

describe("admin_cleanup_workspace tool card", () => {
  it("registers the cleanup tool and catalogs every visible state", () => {
    expect(adminCleanupWorkspaceToolCard.toolName).toBe("admin_cleanup_workspace")
    expect(examples.map((example) => example.id)).toEqual(["pending_cleanup", "confirmed_cleanup", "rejected_cleanup", "cleanup_error"])
  })

  it.each([
    ["structured_content", { structured_content: payload }],
    ["content[0].text", { content: [{ type: "text", text: JSON.stringify(payload) }] }]
  ])("renders all input and result fields from the shared normalized %s envelope", (_label, envelope) => {
    expect(normalizedToolName("mcp__syrus-chat-sidecar__admin_cleanup_workspace")).toBe("admin_cleanup_workspace")
    const parsedResult = redactToolCardValue(normalizedToolCardParsedResult(envelope))

    render(<>{adminCleanupWorkspaceToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByRole("link", { name: "WF-61288" })).toHaveAttribute("href", "/admin/workflows/61288")
    expect(screen.getByText("completed")).toBeInTheDocument()
    expect(screen.getByText("Pending action #501")).toBeInTheDocument()
    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "workflow #61288" })).toHaveAttribute("href", "/admin/workflows/61288")
    expect(screen.getByText("operations")).toBeInTheDocument()

    const card = screen.getByText("Pending action #501").closest("div.rounded-\\[var\\(--radius-panel\\)\\]")
    expect(card).toHaveClass("min-w-0", "overflow-hidden")
    expect(screen.getByRole("link", { name: "WF-61288" })).toHaveClass("break-all")
  })

  it.each([
    ["confirmed", liveAction("confirmed")],
    ["rejected", liveAction("rejected", "Workspace is still needed for **review**.")]
  ])("shows the live %s state", (state, livePendingAction) => {
    render(<>{adminCleanupWorkspaceToolCard.renderExpanded(context({ livePendingAction }))}</>)

    expect(screen.getByText(state)).toBeInTheDocument()
    if (state === "rejected") expect(screen.getByText("review")).toBeInTheDocument()
  })

  it("renders a redacted error together with the linked target and Markdown reason", () => {
    const redacted = redactToolCardValue({
      input: { workflow_id: 61288, reason: "Cleanup requested with token=super-secret-token-value." },
      result: { content: [{ type: "text", text: "Cleanup failed: authorization=super-secret-token-value" }] }
    }) as { input: Record<string, unknown>; result: unknown }

    render(<>{adminCleanupWorkspaceToolCard.renderExpanded(context({ input: redacted.input, parsedResult: redacted.result, resultError: true }))}</>)

    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "WF-61288" })).toHaveAttribute("href", "/admin/workflows/61288")
    expect(screen.getAllByText(/\[redacted\]/).length).toBeGreaterThan(0)
    expect(screen.queryByText(/super-secret-token-value/)).not.toBeInTheDocument()
  })
})
