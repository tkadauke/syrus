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
    expect(cancelWakeupToolCard.toolName).toBe("cancel_wakeup")
  })

  it("summarizes the cancelled wakeup", () => {
    const parsedResult = { cancelled: true, wakeup_id: 7 }
    expect(cancelWakeupToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Cancelled wakeup #7")
  })

  it("renders the cancelled wakeup reference and returned context with responsive wrapping", () => {
    const parsedResult = {
      cancelled: true,
      wakeup_id: 7,
      prompt: "Check the unusually long deployment status and report every relevant failure.",
      fire_at: "2026-10-20T09:30:00Z"
    }

    render(<>{cancelWakeupToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("WAKEUP-7")).toBeInTheDocument()
    expect(screen.getByText("2026-10-20T09:30:00Z")).toBeInTheDocument()
    expect(screen.getByText(parsedResult.prompt)).toHaveClass("break-words")
    expect(screen.getByText("Cancelled wakeup").parentElement).toHaveClass("flex-wrap")
  })

  it("renders the not-found-or-not-pending failure as a styled error card", () => {
    const failure = context({ resultBody: "Error: wakeup not found or not pending", resultError: true })

    expect(cancelWakeupToolCard.collapsedSummary?.(failure)).toBe("Wakeup not cancelled")
    render(<>{cancelWakeupToolCard.renderExpanded(failure)}</>)

    expect(screen.getByText("Wakeup not cancelled")).toBeInTheDocument()
    expect(screen.getByText("Error: wakeup not found or not pending")).toHaveClass("text-red-700")
  })

  it.each([
    ["Claude MCP envelope", "mcp__syrus-chat-sidecar__cancel_wakeup", { content: [{ type: "text", text: '{"cancelled":true,"wakeup_id":8}' }] }],
    ["structured MCP envelope", "syrus-chat-deferred-sidecar.cancel_wakeup", { structured_content: { cancelled: true, wakeup_id: 9 } }]
  ])("normalizes the %s", (_label, toolName, envelope) => {
    const parsedResult = normalizedToolCardParsedResult(envelope)

    expect(normalizedToolName(toolName)).toBe("cancel_wakeup")
    expect(cancelWakeupToolCard.collapsedSummary?.(context({ toolName: normalizedToolName(toolName), parsedResult }))).toMatch(/^Cancelled wakeup #(?:8|9)$/)
  })

  it("falls back to null when cancelled is not true", () => {
    const parsedResult = { cancelled: false, wakeup_id: 7 }
    expect(cancelWakeupToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(cancelWakeupToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }
    expect(cancelWakeupToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(cancelWakeupToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"
    expect(cancelWakeupToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(cancelWakeupToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
