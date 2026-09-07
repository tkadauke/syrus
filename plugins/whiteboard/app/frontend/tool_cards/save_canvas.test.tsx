import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import saveCanvasToolCard from "./save_canvas"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "save_canvas",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("save_canvas tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(saveCanvasToolCard.toolName).toBe("save_canvas")
  })

  it("summarizes and renders a saved snapshot", () => {
    const parsedResult = { saved: true, snapshot_id: 9, name: "Diagram v1", element_count: 4, version: 2 }
    expect(saveCanvasToolCard.collapsedSummary?.(context({ parsedResult }))).toBe('Saved snapshot "Diagram v1"')

    render(<>{saveCanvasToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("Saved snapshot")).toBeInTheDocument()
    expect(screen.getByText("#9")).toBeInTheDocument()
    expect(screen.getByText("Diagram v1")).toBeInTheDocument()
    expect(screen.getByText("4")).toBeInTheDocument()
  })

  it("summarizes and renders an empty-canvas non-save", () => {
    const parsedResult = { saved: false, reason: "canvas is empty", version: 1 }
    expect(saveCanvasToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Canvas not saved (empty)")

    render(<>{saveCanvasToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("Not saved")).toBeInTheDocument()
    expect(screen.getByText("canvas is empty")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload (missing saved flag)", () => {
    expect(saveCanvasToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(saveCanvasToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
