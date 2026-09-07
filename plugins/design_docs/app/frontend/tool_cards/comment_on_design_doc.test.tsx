import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import commentOnDesignDocToolCard from "./comment_on_design_doc"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "comment_on_design_doc",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const parsedResult = {
  design_doc: { doc_ref: "DOC-20", title: "Target Graphs", visibility: "public", state: "draft" },
  doc_ref: "DOC-20",
  thread: { id: 1, state: "open" },
  comment: { id: 5, body: "This section needs a diagram." },
  mutation_mode: "comment_only"
}

describe("comment_on_design_doc tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(commentOnDesignDocToolCard.toolName).toBe("comment_on_design_doc")
  })

  it("summarizes the collapsed row with the doc ref", () => {
    expect(commentOnDesignDocToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Commented on DOC-20")
  })

  it("renders the doc ref, thread state, and comment body", () => {
    render(<>{commentOnDesignDocToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("DOC-20")).toBeInTheDocument()
    expect(screen.getByText("open")).toBeInTheDocument()
    expect(screen.getByText("This section needs a diagram.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload (missing comment)", () => {
    expect(commentOnDesignDocToolCard.collapsedSummary?.(context({ parsedResult: { design_doc: parsedResult.design_doc } }))).toBeNull()
    expect(commentOnDesignDocToolCard.renderExpanded(context({ parsedResult: { design_doc: parsedResult.design_doc } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(commentOnDesignDocToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
