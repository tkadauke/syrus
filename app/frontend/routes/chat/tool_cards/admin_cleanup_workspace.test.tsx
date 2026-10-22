import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { redactToolCardValue } from "@app/toolCardSecurity"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import adminCleanupWorkspaceToolCard from "./admin_cleanup_workspace"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "admin_cleanup_workspace",
    input: { workflow_id: 71, reason: "Remove the **completed** workspace." },
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

function redactedContext(envelope: unknown, overrides: Partial<ToolCardContext> = {}) {
  return context({
    parsedResult: redactToolCardValue(normalizedToolCardParsedResult(envelope)),
    input: redactToolCardValue(context().input) as Record<string, unknown>,
    ...overrides
  })
}

describe("admin_cleanup_workspace tool card", () => {
  it("registers under the exact normalized MCP tool name", () => {
    const rawName = "mcp__syrus-chat-sidecar__admin_cleanup_workspace"

    expect(normalizedToolName(rawName)).toBe("admin_cleanup_workspace")
    expect(adminCleanupWorkspaceToolCard.toolName).toBe(normalizedToolName(rawName))
  })

  it.each([
    [
      "structured_content",
      {
        structured_content: {
          pending_action_id: 501,
          state: "pending",
          reason: "Cleanup was requested by **operations**.",
          message: "Clean workspace for workflow #71?"
        }
      },
      "501"
    ],
    [
      "content[0].text",
      {
        content: [
          {
            type: "text",
            text: JSON.stringify({
              pending_confirmation_id: 502,
              state: "pending",
              reason: "Cleanup was requested by **operations**.",
              message: "Clean workspace for workflow #71?"
            })
          }
        ]
      },
      "502"
    ]
  ])("renders every input and result field from the shared normalized %s envelope", (_label, envelope, pendingId) => {
    render(<>{adminCleanupWorkspaceToolCard.renderExpanded(redactedContext(envelope))}</>)

    expect(screen.getByRole("link", { name: "WF-71" })).toHaveAttribute("href", "/admin/workflows/71")
    expect(screen.getByText("completed")).toBeInTheDocument()
    expect(screen.getByText(`Pending action #${pendingId}`)).toBeInTheDocument()
    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "workflow #71" })).toHaveAttribute("href", "/admin/workflows/71")
    expect(screen.getByText("operations")).toBeInTheDocument()
  })

  it.each(["confirmed", "rejected"])("renders the %s result state", (state) => {
    render(
      <>
        {adminCleanupWorkspaceToolCard.renderExpanded(
          redactedContext({
            structured_content: {
              pending_action_id: 501,
              state,
              reason: state === "rejected" ? "Keep it for **review**." : "Cleanup approved.",
              message: "Workspace cleanup decision recorded."
            }
          })
        )}
      </>
    )

    expect(screen.getByText(state)).toBeInTheDocument()
    expect(screen.getByText(state === "rejected" ? "review" : "Cleanup approved.")).toBeInTheDocument()
  })

  it("renders redacted input and error prose without leaking secrets", () => {
    const input = redactToolCardValue({ workflow_id: 71, reason: "Cleanup requested with token=super-secret-token-value." }) as Record<string, unknown>
    const envelope = redactToolCardValue({ content: [{ type: "text", text: "Cleanup failed: authorization=super-secret-token-value" }] })

    render(
      <>
        {adminCleanupWorkspaceToolCard.renderExpanded(
          redactedContext(envelope, {
            input,
            resultError: true
          })
        )}
      </>
    )

    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "WF-71" })).toHaveAttribute("href", "/admin/workflows/71")
    expect(screen.getAllByText(/\[redacted\]/).length).toBeGreaterThan(0)
    expect(screen.queryByText(/super-secret-token-value/)).not.toBeInTheDocument()
  })

  it("wraps long Markdown prose inside an overflow-safe mobile card", () => {
    const longReason = `**Cleanup context:** ${"long explanation ".repeat(80)}`
    render(
      <>
        {adminCleanupWorkspaceToolCard.renderExpanded(
          redactedContext(
            { structured_content: { pending_action_id: 501, state: "pending", reason: longReason, message: longReason } },
            { input: { workflow_id: 71, reason: longReason } }
          )
        )}
      </>
    )

    const card = screen.getByText("Pending action #501").closest("div.rounded-\\[var\\(--radius-panel\\)\\]")
    expect(card).toHaveClass("min-w-0", "max-w-full", "overflow-hidden")
    expect(screen.getAllByTestId("markdown-preview-content")).toHaveLength(3)
    for (const preview of screen.getAllByTestId("markdown-preview-content")) {
      expect(preview).toHaveClass("break-words", "[overflow-wrap:anywhere]")
    }
  })
})
