import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import writePreviewFileToolCard from "./write_preview_file"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "write_preview_file",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("write_preview_file tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(writePreviewFileToolCard.toolName).toBe("write_preview_file")
  })

  it("summarizes the collapsed row with the path and panel id", () => {
    const parsedResult = { panel_id: "7", path: "index.html" }
    expect(writePreviewFileToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Wrote index.html (panel #7)")
  })

  it("renders the panel id and path", () => {
    const parsedResult = { panel_id: "7", path: "index.html" }
    render(<>{writePreviewFileToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("Wrote file")).toBeInTheDocument()
    expect(screen.getByText("Panel #7")).toBeInTheDocument()
    expect(screen.getByText("index.html")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload (missing path)", () => {
    expect(writePreviewFileToolCard.renderExpanded(context({ parsedResult: { panel_id: "7" } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(writePreviewFileToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
