import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import listDesignDocSectionsToolCard from "./list_design_doc_sections"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "list_design_doc_sections",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const payload = {
  design_doc: {
    doc_ref: "DOC-34",
    title: "Operator Briefing",
    visibility: "private",
    state: "draft"
  },
  sections: [
    { text: "Operator Briefing", level: 1, start_offset: 0, end_offset: 42 },
    { text: "Attention Debt", level: 2, start_offset: 20, end_offset: 42 }
  ]
}

describe("list_design_doc_sections tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(listDesignDocSectionsToolCard.toolName).toBe("list_design_doc_sections")
  })

  it("summarizes the collapsed row with the section count", () => {
    expect(listDesignDocSectionsToolCard.collapsedSummary?.(context({ parsedResult: payload }))).toBe("DOC-34: 2 sections")
  })

  it("renders the outline with heading levels and offsets", () => {
    render(<>{listDesignDocSectionsToolCard.renderExpanded(context({ parsedResult: payload }))}</>)

    expect(screen.getByText("DOC-34")).toBeInTheDocument()
    expect(screen.getAllByText("Operator Briefing")).toHaveLength(2)
    expect(screen.getByText("H1")).toBeInTheDocument()
    expect(screen.getByText("Attention Debt")).toBeInTheDocument()
    expect(screen.getByText("H2")).toBeInTheDocument()
    expect(screen.getByText("20-42")).toBeInTheDocument()
  })

  it("renders an empty-section state", () => {
    render(<>{listDesignDocSectionsToolCard.renderExpanded(context({ parsedResult: { ...payload, sections: [] } }))}</>)

    expect(screen.getByText("No headings found.")).toBeInTheDocument()
  })

  it("falls back to null for malformed payloads", () => {
    expect(listDesignDocSectionsToolCard.collapsedSummary?.(context({ parsedResult: { sections: [] } }))).toBeNull()
    expect(listDesignDocSectionsToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
