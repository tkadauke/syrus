import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import editPreviewFileToolCard from "./edit_preview_file"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "edit_preview_file",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("edit_preview_file tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(editPreviewFileToolCard.toolName).toBe("edit_preview_file")
  })

  it("summarizes the collapsed row with the path and panel id", () => {
    const parsedResult = { panel_id: "7", path: "index.html", replacements: 2 }
    expect(editPreviewFileToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Edited index.html (panel #7)")
  })

  it("renders the panel id, path, and replacement count", () => {
    const parsedResult = { panel_id: "7", path: "index.html", replacements: 2 }
    render(<>{editPreviewFileToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("Edited file")).toBeInTheDocument()
    expect(screen.getByText("Panel #7")).toBeInTheDocument()
    expect(screen.getByText("index.html")).toBeInTheDocument()
    expect(screen.getByText("2")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload (missing path)", () => {
    expect(editPreviewFileToolCard.renderExpanded(context({ parsedResult: { panel_id: "7" } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(editPreviewFileToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
