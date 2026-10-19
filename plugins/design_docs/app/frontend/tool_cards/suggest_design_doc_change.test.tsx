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
    change_summary: "Clarify the **monorepo** section for DOC-29",
    conflict_reason: null,
    suggested_by_kind: "agent",
    original_markdown: "Old text",
    proposed_markdown: "New text",
    anchor: { anchor_kind: "range", start_offset: 12, end_offset: 20, status: "active" },
    thread: { id: 7, state: "open" }
  },
  version: { version_number: 6 },
  mutation_mode: "suggestion_only"
}

describe("suggest_design_doc_change tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(suggestDesignDocChangeToolCard.toolName).toBe("suggest_design_doc_change")
  })

  it("summarizes the collapsed row with the doc ref and suggestion state", () => {
    expect(suggestDesignDocChangeToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Suggested change to DOC-20 (pending)")
  })

  it("renders the doc ref, suggestion state, change type, and summary", () => {
    render(<>{suggestDesignDocChangeToolCard.renderExpanded(context({ parsedResult, input: { base_version_number: 5, occurrence_index: 2 } }))}</>)

    expect(screen.getByText("DOC-20")).toBeInTheDocument()
    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("block edit")).toBeInTheDocument()
    expect(screen.getByText("monorepo").tagName).toBe("STRONG")
    expect(screen.getByText("Old text")).toBeInTheDocument()
    expect(screen.getByText("New text")).toBeInTheDocument()
    expect(screen.getByText("agent")).toBeInTheDocument()
    expect(screen.getByText("6")).toBeInTheDocument()
    expect(screen.getByText("5")).toBeInTheDocument()
    expect(screen.getByText("2")).toBeInTheDocument()
    expect(screen.getByText("range · 12–20")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /Thread #7/ })).toHaveAttribute("href", "/design_docs/20?thread=7")
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

  it("renders multiline ambiguity errors with offsets in a styled error card", () => {
    const message = "original_markdown appears twice.\nOccurrence 1: start_offset=10, end_offset=14\nOccurrence 2: start_offset=50, end_offset=54"
    render(<>{suggestDesignDocChangeToolCard.renderExpanded(context({ resultBody: message, resultError: true }))}</>)

    const alert = screen.getByRole("alert")
    expect(alert).toHaveTextContent("start_offset=10, end_offset=14")
    expect(alert).toHaveClass("whitespace-pre-wrap")
  })

  it("renders stale-version errors from a structured error envelope", () => {
    render(
      <>
        {suggestDesignDocChangeToolCard.renderExpanded(
          context({ parsedResult: { error: "stale offsets\nbase 4, current 5" }, resultBody: "encoded", resultError: true })
        )}
      </>
    )
    expect(screen.getByRole("alert")).toHaveTextContent("stale offsets base 4, current 5")
  })

  it("accepts direct, result, and MCP content envelopes", () => {
    expect(suggestDesignDocChangeToolCard.collapsedSummary?.(context({ parsedResult: { result: parsedResult } }))).toBe("Suggested change to DOC-20 (pending)")
    expect(suggestDesignDocChangeToolCard.collapsedSummary?.(context({ parsedResult: { data: parsedResult } }))).toBe("Suggested change to DOC-20 (pending)")
    expect(
      suggestDesignDocChangeToolCard.collapsedSummary?.(context({ parsedResult: { content: [{ type: "text", text: JSON.stringify(parsedResult) }] } }))
    ).toBe("Suggested change to DOC-20 (pending)")
  })

  it("renders pending and delete-only empty states", () => {
    render(<>{suggestDesignDocChangeToolCard.renderExpanded(context())}</>)
    expect(screen.getByText("Waiting for the tool result.")).toBeInTheDocument()

    const deleted = { ...parsedResult, suggestion: { ...parsedResult.suggestion, proposed_markdown: "" } }
    render(<>{suggestDesignDocChangeToolCard.renderExpanded(context({ parsedResult: deleted }))}</>)
    expect(screen.getByText("No proposed text (deletion).")).toBeInTheDocument()
  })
})
