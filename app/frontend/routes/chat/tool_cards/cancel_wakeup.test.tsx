import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import cancelWakeupToolCard from "./cancel_wakeup"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "cancel_wakeup", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("cancel_wakeup tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(cancelWakeupToolCard.toolName).toBe(normalizedToolName("mcp__provider__cancel_wakeup"))
  })

  it("summarizes the cancelled wakeup", () => {
    const parsedResult = { cancelled: true, wakeup_id: 7 }
    expect(cancelWakeupToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Cancelled wakeup #7")
  })

  it("renders a linked cancelled wakeup with returned prompt and fire time", () => {
    const parsedResult = normalizedToolCardParsedResult({
      structured_content: { cancelled: true, wakeup_id: 7, fire_at: "2026-12-01T15:30:00Z", prompt: "Review JOB-42" }
    })

    render(<>{cancelWakeupToolCard.renderExpanded(context({ parsedResult, chatSessionId: 9 }))}</>)

    expect(screen.getByRole("link", { name: "WAKEUP-7" })).toHaveAttribute("href", "/chats/9")
    expect(screen.getByTestId("markdown-preview-content")).toHaveTextContent("Review JOB-42")
    expect(screen.getByText("2026-12-01T15:30:00.000Z UTC")).toBeInTheDocument()
  })

  it("renders an empty state when cancelled is not true", () => {
    const parsedResult = { cancelled: false, wakeup_id: 7 }
    expect(cancelWakeupToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    render(<>{cancelWakeupToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("No cancellation result was returned.")).toBeInTheDocument()
  })

  it("renders a styled not-found or not-pending error from an MCP content envelope", () => {
    const parsedResult = normalizedToolCardParsedResult({ content: [{ type: "text", text: "wakeup not found or not pending" }], isError: true })
    const cardContext = context({ parsedResult, resultError: true })
    expect(cancelWakeupToolCard.collapsedSummary?.(cardContext)).toBe("Wakeup cancellation failed: wakeup not found or not pending")
    render(<>{cancelWakeupToolCard.renderExpanded(cardContext)}</>)
    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("wakeup not found or not pending")).toHaveClass("text-danger-text")
  })

  it("recovers context from an earlier list result for legacy success envelopes", () => {
    const parsedResult = normalizedToolCardParsedResult({ content: [{ type: "text", text: JSON.stringify({ cancelled: true, wakeup_id: 7 }) }] })
    render(
      <>
        {cancelWakeupToolCard.renderExpanded(
          context({
            parsedResult,
            priorCalls: [
              {
                toolName: normalizedToolName("syrus-chat-sidecar.list_wakeups"),
                input: {},
                parsedResult: { wakeups: [{ id: 7, fire_at: "2026-12-01T15:30:00Z", prompt: "Legacy prompt" }] }
              }
            ]
          })
        )}
      </>
    )
    expect(screen.getByText("Legacy prompt")).toBeInTheDocument()
    expect(screen.getByText("2026-12-01T15:30:00.000Z UTC")).toBeInTheDocument()
  })

  it("renders the pending state before a result settles", () => {
    const cardContext = context({ resultSettled: false })
    expect(cancelWakeupToolCard.collapsedSummary?.(cardContext)).toBe("Cancelling wakeup...")
    render(<>{cancelWakeupToolCard.renderPending?.(cardContext)}</>)
    expect(screen.getByText("pending")).toBeInTheDocument()
  })
})
