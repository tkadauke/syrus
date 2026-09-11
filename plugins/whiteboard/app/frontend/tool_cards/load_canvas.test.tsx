import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import loadCanvasToolCard from "./load_canvas"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "load_canvas",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("load_canvas tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(loadCanvasToolCard.toolName).toBe("load_canvas")
  })

  it("summarizes and renders a merge load", () => {
    const parsedResult = { loaded: true, elements_added: 6, auto_saved_snapshot_id: null, snapshot_id: 8, mode: "merge", version: 3 }
    expect(loadCanvasToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Loaded #8 (merge)")

    render(<>{loadCanvasToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("Loaded snapshot")).toBeInTheDocument()
    expect(screen.getByText("#8")).toBeInTheDocument()
    expect(screen.getAllByText("merge").length).toBeGreaterThan(0)
    expect(screen.getByText("6")).toBeInTheDocument()
  })

  it("renders the auto-saved snapshot id for a replace load", () => {
    const parsedResult = { loaded: true, elements_added: 6, auto_saved_snapshot_id: 4, snapshot_id: 8, mode: "replace", version: 3 }
    render(<>{loadCanvasToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("#4")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload (loaded not true)", () => {
    expect(loadCanvasToolCard.renderExpanded(context({ parsedResult: { loaded: false } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(loadCanvasToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
