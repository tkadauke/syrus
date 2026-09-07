import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
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

  it("renders the cancelled wakeup id", () => {
    const parsedResult = { cancelled: true, wakeup_id: 7 }

    render(<>{cancelWakeupToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("#7")).toBeInTheDocument()
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
