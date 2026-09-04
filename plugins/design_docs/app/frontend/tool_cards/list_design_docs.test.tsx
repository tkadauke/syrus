import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import listDesignDocsToolCard from "./list_design_docs"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "list_design_docs",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("list_design_docs tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(listDesignDocsToolCard.toolName).toBe("list_design_docs")
  })

  it("summarizes the collapsed row with a doc count", () => {
    const parsedResult = { design_docs: [{ id: 1, doc_ref: "DOC-1", title: "A" }, { id: 2, doc_ref: "DOC-2", title: "B" }] }

    expect(listDesignDocsToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("2 design docs")
  })

  it("renders a row per design doc with its doc ref, title, and state", () => {
    const parsedResult = {
      design_docs: [
        { id: 1, doc_ref: "DOC-20", title: "Target Graphs for Project-Aware Workflows", state: "draft" }
      ]
    }

    render(<>{listDesignDocsToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("DOC-20")).toBeInTheDocument()
    expect(screen.getByText("Target Graphs for Project-Aware Workflows")).toBeInTheDocument()
    expect(screen.getByText("draft")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload (missing design_docs array)", () => {
    expect(listDesignDocsToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(listDesignDocsToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(listDesignDocsToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })

  it("falls back to null for an empty design_docs list", () => {
    expect(listDesignDocsToolCard.renderExpanded(context({ parsedResult: { design_docs: [] } }))).toBeNull()
  })
})
