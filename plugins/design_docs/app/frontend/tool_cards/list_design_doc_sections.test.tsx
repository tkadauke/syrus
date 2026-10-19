import { fireEvent, render, screen } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult } from "@app/routes/chat/toolRendering"
import listDesignDocSectionsToolCard from "./list_design_doc_sections"

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
    updated_at: "2026-10-18T12:34:56Z"
  },
  sections: [
    { text: "Operator Briefing", level: 1, start_offset: 0, end_offset: 42 },
    { text: "A very long attention debt heading that must wrap instead of disappearing on a narrow screen", level: 2, start_offset: 20, end_offset: 42 }
  ],
  read_only: true,
  reference_format: "DOC-34"
}

describe("list_design_doc_sections tool card", () => {
  beforeEach(() => {
    Object.assign(navigator, { clipboard: { writeText: vi.fn().mockResolvedValue(undefined) } })
  })

  it("registers under the exact MCP tool name and summarizes the valid section count", () => {
    expect(listDesignDocSectionsToolCard.toolName).toBe("list_design_doc_sections")
    expect(listDesignDocSectionsToolCard.collapsedSummary?.(context({ parsedResult: payload }))).toBe("DOC-34: 2 sections")
  })

  it("renders every input and result field with linkable entities linked", () => {
    render(
      <>
        {listDesignDocSectionsToolCard.renderExpanded(
          context({
            input: { doc_ref: "DOC-34", query: "attention", filters: { levels: [1, 2] } },
            parsedResult: payload
          })
        )}
      </>
    )

    expect(screen.getAllByRole("link", { name: "DOC-34" })).toHaveLength(2)
    expect(screen.getAllByRole("link", { name: "DOC-34" })[0]).toHaveAttribute("href", "/design_docs/34")
    expect(screen.getByText("Query")).toBeInTheDocument()
    expect(screen.getByText("attention")).toBeInTheDocument()
    expect(screen.getByText("Filters")).toBeInTheDocument()
    expect(screen.getByText('{"levels":[1,2]}')).toBeInTheDocument()
    expect(screen.getAllByText("Operator Briefing")).toHaveLength(2)
    expect(screen.getByText("draft")).toBeInTheDocument()
    expect(screen.getByText("private")).toBeInTheDocument()
    expect(screen.getByText("Read only")).toBeInTheDocument()
    expect(screen.getByText("v45")).toBeInTheDocument()
    expect(screen.getByText("Updated 2026-10-18T12:34:56Z")).toBeInTheDocument()
    expect(screen.getByText("Reference: DOC-34")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Repository 41" })).toHaveAttribute("href", "/repositories/41")
    expect(screen.getByRole("link", { name: "Repository 42" })).toHaveAttribute("href", "/repositories/42")
  })

  it("wraps nested headings without inline indentation and provides touch-sized offset copy buttons", () => {
    const { container } = render(<>{listDesignDocSectionsToolCard.renderExpanded(context({ parsedResult: payload }))}</>)

    const heading = screen.getByText(/A very long attention debt/)
    expect(heading).toHaveClass("whitespace-normal", "break-words", "ml-3")
    expect(heading).not.toHaveAttribute("style")
    expect(screen.getByText("H2")).toBeInTheDocument()

    const startCopy = screen.getByRole("button", { name: "Copy offset 20 to clipboard" })
    const endCopies = screen.getAllByRole("button", { name: "Copy offset 42 to clipboard" })
    expect(startCopy).toHaveClass("h-8", "w-8")
    fireEvent.click(startCopy)
    fireEvent.click(endCopies[1])
    expect(navigator.clipboard.writeText).toHaveBeenNthCalledWith(1, "20")
    expect(navigator.clipboard.writeText).toHaveBeenNthCalledWith(2, "42")
    expect(container.querySelector('[aria-label="Offsets 20 through 42"]')).toBeInTheDocument()
  })

  it("reports malformed rows instead of silently dropping them", () => {
    const malformed = { ...payload, sections: [...payload.sections, null, { text: "No offsets", level: 3 }] }
    render(<>{listDesignDocSectionsToolCard.renderExpanded(context({ parsedResult: malformed }))}</>)

    expect(screen.getByRole("status")).toHaveTextContent("Skipped 2 malformed section rows.")
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
    expect(listDesignDocSectionsToolCard.collapsedSummary?.(context({ parsedResult: malformed }))).toBe("DOC-34: 2 sections")
  })

  it("renders dedicated empty, pending, and error states", () => {
    const { rerender } = render(<>{listDesignDocSectionsToolCard.renderExpanded(context({ parsedResult: { ...payload, sections: [] } }))}</>)
    expect(screen.getByText("No headings found.")).toBeInTheDocument()

    rerender(<>{listDesignDocSectionsToolCard.renderExpanded(context())}</>)
    expect(screen.getByText("Waiting for the tool result.")).toBeInTheDocument()
    expect(listDesignDocSectionsToolCard.collapsedSummary?.(context())).toBe("Listing design doc sections")

    const errorContext = context({ resultBody: "Error: design doc not found", resultError: true })
    rerender(<>{listDesignDocSectionsToolCard.renderExpanded(errorContext)}</>)
    expect(screen.getByRole("alert")).toHaveTextContent("Error: design doc not found")
    expect(listDesignDocSectionsToolCard.collapsedSummary?.(errorContext)).toBe("Could not list design doc sections")
  })

  it.each([
    ["direct", payload],
    ["Codex content", { content: [{ type: "text", text: JSON.stringify(payload) }], structured_content: null }],
    ["structured content", { content: [{ type: "text", text: "{}" }], structured_content: payload }]
  ])("renders a %s result envelope", (_label, envelope) => {
    render(
      <>
        {listDesignDocSectionsToolCard.renderExpanded(
          context({
            resultBody: JSON.stringify(envelope),
            parsedResult: normalizedToolCardParsedResult(envelope)
          })
        )}
      </>
    )

    expect(screen.getByRole("link", { name: "DOC-34" })).toHaveAttribute("href", "/design_docs/34")
    expect(screen.getByText(/A very long attention debt/)).toBeInTheDocument()
  })

  it("falls back to null for malformed top-level payloads while preserving security-normalized context", () => {
    expect(listDesignDocSectionsToolCard.collapsedSummary?.(context({ parsedResult: { sections: [] } }))).toBeNull()
    expect(listDesignDocSectionsToolCard.renderExpanded(context({ parsedResult: "not json", resultBody: "not json" }))).toBeNull()
  })
})
