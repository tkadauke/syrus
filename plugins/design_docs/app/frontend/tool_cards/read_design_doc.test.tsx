import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import readDesignDocToolCard from "./read_design_doc"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "read_design_doc",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const designDoc = {
  doc_ref: "DOC-20",
  title: "Target Graphs for Project-Aware Workflows",
  visibility: "public",
  state: "draft",
  pending_suggestions_count: 2,
  open_threads_count: 1,
  markdown: "one two three four five"
}

describe("read_design_doc tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(readDesignDocToolCard.toolName).toBe("read_design_doc")
  })

  it("summarizes the collapsed row with the doc ref and title", () => {
    expect(readDesignDocToolCard.collapsedSummary?.(context({ parsedResult: { design_doc: designDoc } }))).toBe(
      "DOC-20 — Target Graphs for Project-Aware Workflows"
    )
  })

  it("renders doc ref, title, status, and concise content metadata", () => {
    render(<>{readDesignDocToolCard.renderExpanded(context({ parsedResult: { design_doc: designDoc } }))}</>)

    expect(screen.getByText("DOC-20")).toBeInTheDocument()
    expect(screen.getByText("Target Graphs for Project-Aware Workflows")).toBeInTheDocument()
    expect(screen.getByText("draft")).toBeInTheDocument()
    expect(screen.getByText("public")).toBeInTheDocument()
    expect(screen.getByText("2")).toBeInTheDocument()
    expect(screen.getByText("1")).toBeInTheDocument()
    expect(screen.getByText("5 words")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload (missing design_doc)", () => {
    expect(readDesignDocToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(readDesignDocToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(readDesignDocToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
