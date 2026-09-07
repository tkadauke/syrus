import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import suggestDesignDocChangeToolCard from "./suggest_design_doc_change"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "suggest_design_doc_change",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const parsedResult = {
  design_doc: { doc_ref: "DOC-20", title: "Target Graphs", visibility: "public", state: "draft" },
  doc_ref: "DOC-20",
  suggestion: {
    state: "pending",
    change_type: "block_edit",
    change_summary: "Clarify the monorepo section",
    conflict_reason: null
  },
  mutation_mode: "suggestion_only"
}

describe("suggest_design_doc_change tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(suggestDesignDocChangeToolCard.toolName).toBe("suggest_design_doc_change")
  })

  it("summarizes the collapsed row with the doc ref and suggestion state", () => {
    expect(suggestDesignDocChangeToolCard.collapsedSummary?.(context({ parsedResult }))).toBe(
      "Suggested change to DOC-20 (pending)"
    )
  })

  it("renders the doc ref, suggestion state, change type, and summary", () => {
    render(<>{suggestDesignDocChangeToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("DOC-20")).toBeInTheDocument()
    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("block edit")).toBeInTheDocument()
    expect(screen.getByText("Clarify the monorepo section")).toBeInTheDocument()
  })

  it("renders a conflict callout when the suggestion could not apply cleanly", () => {
    const conflicted = { ...parsedResult, suggestion: { ...parsedResult.suggestion, conflict_reason: "stale offsets" } }
    render(<>{suggestDesignDocChangeToolCard.renderExpanded(context({ parsedResult: conflicted }))}</>)

    expect(screen.getByText("Conflict")).toBeInTheDocument()
    expect(screen.getByText("stale offsets")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload (missing suggestion)", () => {
    expect(suggestDesignDocChangeToolCard.collapsedSummary?.(context({ parsedResult: { design_doc: parsedResult.design_doc } }))).toBeNull()
    expect(suggestDesignDocChangeToolCard.renderExpanded(context({ parsedResult: { design_doc: parsedResult.design_doc } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(suggestDesignDocChangeToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
