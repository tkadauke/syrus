import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import closePreviewToolCard from "./close_preview"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "close_preview",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("close_preview tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(closePreviewToolCard.toolName).toBe("close_preview")
  })

  it("summarizes the collapsed row with the closed state", () => {
    const parsedResult = { panel_id: "7", title: "Landing page", state: "closed" }
    expect(closePreviewToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Landing page (closed)")
  })

  it("renders the panel id and closed state", () => {
    const parsedResult = { panel_id: "7", title: "Landing page", state: "closed" }
    render(<>{closePreviewToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("Panel #7")).toBeInTheDocument()
    expect(screen.getAllByText("closed").length).toBeGreaterThan(0)
  })

  it("falls back to null for a malformed payload", () => {
    expect(closePreviewToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(closePreviewToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
