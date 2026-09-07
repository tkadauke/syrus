import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import clearCanvasToolCard from "./clear_canvas"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "clear_canvas",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("clear_canvas tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(clearCanvasToolCard.toolName).toBe("clear_canvas")
  })

  it("summarizes and renders an auto-saved snapshot reference", () => {
    const parsedResult = { cleared: true, snapshot_id: 3, version: 4 }
    expect(clearCanvasToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Cleared canvas (saved as #3)")

    render(<>{clearCanvasToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("Cleared canvas")).toBeInTheDocument()
    expect(screen.getByText("#3")).toBeInTheDocument()
  })

  it("summarizes and renders an already-empty canvas", () => {
    const parsedResult = { cleared: true, snapshot_id: null, version: 1 }
    expect(clearCanvasToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Cleared canvas")

    render(<>{clearCanvasToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("Canvas was already empty.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload (cleared not true)", () => {
    expect(clearCanvasToolCard.renderExpanded(context({ parsedResult: { cleared: false } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(clearCanvasToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
