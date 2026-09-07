import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import proposeDesignDocToolCard from "./propose_design_doc"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "propose_design_doc",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const parsedResult = {
  design_doc: { doc_ref: "DOC-42", title: "New Doc", visibility: "private", state: "draft" },
  doc_ref: "DOC-42",
  mutation_mode: "new_doc_created",
  note: "For existing DOC-<id> content changes, use suggest_design_doc_change."
}

describe("propose_design_doc tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(proposeDesignDocToolCard.toolName).toBe("propose_design_doc")
  })

  it("summarizes the collapsed row as a creation", () => {
    expect(proposeDesignDocToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Created DOC-42 — New Doc")
  })

  it("renders the created doc ref, title, status, and note", () => {
    render(<>{proposeDesignDocToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("Created")).toBeInTheDocument()
    expect(screen.getByText("DOC-42")).toBeInTheDocument()
    expect(screen.getByText("New Doc")).toBeInTheDocument()
    expect(screen.getByText("draft")).toBeInTheDocument()
    expect(screen.getByText("private")).toBeInTheDocument()
    expect(screen.getByText(parsedResult.note)).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(proposeDesignDocToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(proposeDesignDocToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(proposeDesignDocToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
