import { fireEvent, render, screen } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "@app/routes/chat/toolRendering"
import listDesignDocSectionsToolCard, { examples } from "./list_design_doc_sections"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "list_design_doc_sections", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

const payload = {
  design_doc: {
    id: 34,
    doc_ref: "DOC-34",
    title: "Operator Briefing",
    visibility: "private",
    state: "draft",
    repository_ids: [41, "42"],
    current_version_number: 45,
    updated_at: "2026-10-19T08:00:00Z"
  },
  sections: [
    { text: "Operator Briefing", level: 1, start_offset: 0, end_offset: 42 },
    { text: "Attention Debt", level: 2, start_offset: 20, end_offset: 42 }
  ],
  read_only: true,
  reference_format: "DOC-34"
}

describe("list_design_doc_sections tool card", () => {
  beforeEach(() => {
    Object.assign(navigator, { clipboard: { writeText: vi.fn().mockResolvedValue(undefined) } })
  })

  it("registers under the exact MCP tool name", () => {
    expect(listDesignDocSectionsToolCard.toolName).toBe("list_design_doc_sections")
  })

  it("summarizes the collapsed row with the valid section count", () => {
    expect(listDesignDocSectionsToolCard.collapsedSummary?.(context({ parsedResult: payload }))).toBe("DOC-34: 2 sections")
  })

  it("renders all input and result metadata, linked doc reference, and copyable offsets", () => {
    render(
      <>
        {listDesignDocSectionsToolCard.renderExpanded(context({ input: { doc_ref: "DOC-34", query: "debt", filters: { level: 2 } }, parsedResult: payload }))}
      </>
    )

    expect(screen.getByRole("link", { name: "DOC-34" })).toHaveAttribute("href", "/design_docs/34")
    fireEvent.click(screen.getByRole("button", { name: "Copy DOC-34 to clipboard" }))
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith("DOC-34")
    expect(screen.getByText("draft")).toBeInTheDocument()
    expect(screen.getByText("private")).toBeInTheDocument()
    expect(screen.getByText("Read only")).toBeInTheDocument()
    expect(screen.getByText("v45")).toBeInTheDocument()
    expect(screen.getByText("Updated 2026-10-19T08:00:00Z")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Repository 41" })).toHaveAttribute("href", "/repositories/41")
    expect(screen.getByRole("link", { name: "Repository 42" })).toHaveAttribute("href", "/repositories/42")
    expect(screen.getByText("Document reference")).toBeInTheDocument()
    expect(screen.getByText("Query")).toBeInTheDocument()
    expect(screen.getByText("debt")).toBeInTheDocument()
    expect(screen.getByText("Filters")).toBeInTheDocument()
    expect(screen.getByText('{"level":2}')).toBeInTheDocument()
    expect(screen.getByText("Reference format")).toBeInTheDocument()
    expect(screen.getByText("H1")).toBeInTheDocument()
    expect(screen.getByText("H2")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Copy start offset 20" }))
    fireEvent.click(screen.getAllByRole("button", { name: "Copy end offset 42" })[0])
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith("20")
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith("42")
  })

  it("wraps long headings, uses class-based nesting, and gives offset controls mobile touch targets", () => {
    const longText = "A deliberately long nested heading that needs to wrap on a narrow mobile card"
    const { container } = render(
      <>
        {listDesignDocSectionsToolCard.renderExpanded(
          context({ parsedResult: { ...payload, sections: [{ text: longText, level: 3, start_offset: 20, end_offset: 42 }] } })
        )}
      </>
    )

    const heading = screen.getByText(longText)
    expect(heading).toHaveClass("whitespace-normal", "break-words", "pl-4", "sm:pl-6")
    expect(heading).not.toHaveClass("truncate")
    expect(heading).not.toHaveAttribute("style")
    expect(container.querySelector("li")).toHaveClass("flex", "min-w-0")
    expect(screen.getByRole("button", { name: "Copy start offset 20" })).toHaveClass("h-9", "w-9", "sm:h-7", "sm:w-7")
  })

  it("reports malformed rows without rendering them", () => {
    const malformed = { ...payload, sections: [...payload.sections, { text: "Broken", level: "deep", start_offset: 43, end_offset: 50 }, null] }
    render(<>{listDesignDocSectionsToolCard.renderExpanded(context({ parsedResult: malformed }))}</>)

    expect(screen.getByRole("status")).toHaveTextContent("Skipped 2 malformed section rows.")
    expect(screen.queryByText("Broken")).not.toBeInTheDocument()
    expect(listDesignDocSectionsToolCard.collapsedSummary?.(context({ parsedResult: malformed }))).toBe("DOC-34: 2 sections")
  })

  it.each([
    ["fractional heading level", { text: "Fractional", level: 2.5, start_offset: 43, end_offset: 50 }],
    ["heading level below one", { text: "Too shallow", level: 0, start_offset: 43, end_offset: 50 }],
    ["heading level above six", { text: "Too deep", level: 7, start_offset: 43, end_offset: 50 }],
    ["negative start offset", { text: "Negative start", level: 2, start_offset: -1, end_offset: 50 }],
    ["negative end offset", { text: "Negative end", level: 2, start_offset: 0, end_offset: -1 }],
    ["fractional start offset", { text: "Fractional start", level: 2, start_offset: 43.5, end_offset: 50 }],
    ["fractional end offset", { text: "Fractional end", level: 2, start_offset: 43, end_offset: 50.5 }],
    ["reversed offset range", { text: "Reversed", level: 2, start_offset: 50, end_offset: 43 }]
  ])("counts a %s row as malformed", (_description, invalidSection) => {
    const malformed = { ...payload, sections: [...payload.sections, invalidSection] }
    render(<>{listDesignDocSectionsToolCard.renderExpanded(context({ parsedResult: malformed }))}</>)
    expect(screen.getByRole("status")).toHaveTextContent("Skipped 1 malformed section row.")
    expect(screen.queryByText(invalidSection.text)).not.toBeInTheDocument()
  })

  it("renders dedicated empty, pending, and error states", () => {
    const { rerender } = render(<>{listDesignDocSectionsToolCard.renderExpanded(context({ parsedResult: { ...payload, sections: [] } }))}</>)
    expect(screen.getByText("No headings found.")).toBeInTheDocument()

    rerender(<>{listDesignDocSectionsToolCard.renderExpanded(context())}</>)
    expect(screen.getByText("Waiting for the tool result.")).toBeInTheDocument()
    expect(listDesignDocSectionsToolCard.collapsedSummary?.(context())).toBe("Listing design doc sections")

    rerender(<>{listDesignDocSectionsToolCard.renderExpanded(context({ resultBody: "Error: design doc not found", resultError: true }))}</>)
    expect(screen.getByRole("alert")).toHaveTextContent("Error: design doc not found")
    expect(listDesignDocSectionsToolCard.collapsedSummary?.(context({ resultError: true }))).toBe("Could not list design doc sections")
  })

  it("renders provider-agnostically after tool-name and differently shaped MCP-envelope normalization", () => {
    const envelopes = [{ structured_content: payload }, { content: [{ type: "text", text: JSON.stringify(payload) }] }]
    for (const envelope of envelopes) {
      const toolName = normalizedToolName("mcp__design_docs__list_design_doc_sections")
      const { unmount } = render(
        <>{listDesignDocSectionsToolCard.renderExpanded(context({ toolName, parsedResult: normalizedToolCardParsedResult(envelope) }))}</>
      )
      expect(screen.getByText("Attention Debt")).toBeInTheDocument()
      unmount()
    }
  })

  it("falls back for malformed envelopes and exposes catalog examples for result states", () => {
    expect(listDesignDocSectionsToolCard.renderExpanded(context({ parsedResult: { sections: [] } }))).toBeNull()
    expect(listDesignDocSectionsToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
    expect(examples.map((example) => example.id)).toEqual(["nested_sections", "no_sections", "not_found"])
  })
})
