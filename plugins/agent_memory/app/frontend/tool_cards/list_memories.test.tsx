import { fireEvent, render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { beforeEach, describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { setSlugReferenceRegistryForTests } from "@app/lib/slugReferenceRegistry"
import { normalizedToolCardParsedResult } from "@app/routes/chat/toolRendering"
import listMemoriesToolCard from "./list_memories"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "list_memories",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const globalMemory = {
  id: 7,
  kind: "user_pref",
  scope: "global",
  scope_id: null,
  content: "Prefers terse responses.",
  published: false,
  updated_at: "2026-09-01T12:00:00Z"
}

const publishedRepoMemory = {
  id: 8,
  kind: "decision",
  scope: "repository",
  scope_id: 42,
  content: "Use policy objects for enum branching.",
  published: true,
  updated_at: "2026-09-02T08:30:00Z"
}

beforeEach(() => {
  setSlugReferenceRegistryForTests([
    {
      prefix: "JOB",
      type: "job",
      displayLabel: "Job",
      copyable: true,
      linkable: true,
      previewAvailable: false,
      linkifiesGeneratedText: true,
      hrefTemplate: "/jobs/:id",
      mobileInteractionHints: {},
      pluginPreviewComponent: null
    }
  ])
})

describe("list_memories tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(listMemoriesToolCard.toolName).toBe("list_memories")
  })

  it("summarizes the collapsed row with a memory count", () => {
    expect(listMemoriesToolCard.collapsedSummary?.(context({ parsedResult: { memories: [globalMemory, publishedRepoMemory] } }))).toBe("2 memories")
  })

  it("singularizes the collapsed summary for one memory", () => {
    expect(listMemoriesToolCard.collapsedSummary?.(context({ parsedResult: { memories: [globalMemory] } }))).toBe("1 memory")
  })

  it("renders linked ids, kind, scope, content preview, and updated_at for a global memory", () => {
    render(<>{listMemoriesToolCard.renderExpanded(context({ parsedResult: { memories: [globalMemory] } }))}</>)

    expect(screen.getAllByRole("link", { name: /MEMORY-7/ })).toHaveLength(2)
    expect(screen.getAllByText("user pref")).toHaveLength(2)
    expect(screen.getAllByText("global")).toHaveLength(2)
    expect(screen.getAllByText("Prefers terse responses.")).toHaveLength(2)
    expect(screen.getAllByText("2026-09-01T12:00:00Z")).toHaveLength(2)
    expect(screen.queryByText("published")).not.toBeInTheDocument()
    expect(screen.queryByText("private")).not.toBeInTheDocument()
  })

  it("shows a published pill and repository scope for a published repository memory", () => {
    render(<>{listMemoriesToolCard.renderExpanded(context({ parsedResult: { memories: [publishedRepoMemory] } }))}</>)

    expect(screen.getAllByText("decision")).toHaveLength(2)
    expect(screen.getAllByText("repository #42")).toHaveLength(2)
    expect(screen.getAllByText("published")).toHaveLength(2)
  })

  it("renders a friendly empty state for no memories", () => {
    render(<>{listMemoriesToolCard.renderExpanded(context({ parsedResult: { memories: [] } }))}</>)

    expect(screen.getByText("No memories match these filters.")).toBeInTheDocument()
  })

  it("does not show a show-more button for short content", () => {
    render(<>{listMemoriesToolCard.renderExpanded(context({ parsedResult: { memories: [globalMemory] } }))}</>)

    expect(screen.queryByText("Show more")).not.toBeInTheDocument()
  })

  it("shows a show-more button for long content that opens a markdown-rendered modal", () => {
    const longContent = Array.from({ length: 10 }, (_, i) => `line ${i}`).join("\n")
    render(<>{listMemoriesToolCard.renderExpanded(context({ parsedResult: { memories: [{ ...globalMemory, content: longContent }] } }))}</>)

    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
    fireEvent.click(screen.getAllByText("Show more")[0])

    const dialog = screen.getByRole("dialog")
    expect(dialog).toBeInTheDocument()
    expect(dialog).toHaveTextContent("line 0")
    expect(dialog).toHaveTextContent("line 9")
  })

  it("also shows the show-more button for a single long wrapped paragraph with no line breaks", () => {
    const longParagraph = "word ".repeat(80).trim()
    render(<>{listMemoriesToolCard.renderExpanded(context({ parsedResult: { memories: [{ ...globalMemory, content: longParagraph }] } }))}</>)

    expect(screen.getAllByText("Show more")).toHaveLength(2)
  })

  it("shows the show-more button in the narrow list column for a moderate one-line paragraph that would still wrap past 3 lines there", () => {
    // ~240 chars, no literal newlines: comfortably 3 lines or fewer against a
    // wide/full-card estimate, but wraps to well over 3 real lines in the
    // list table's narrow content column -- the exact case the "too much
    // text shown by default" bug report was about.
    const moderateParagraph = "word ".repeat(48).trim()
    render(<>{listMemoriesToolCard.renderExpanded(context({ parsedResult: { memories: [{ ...globalMemory, content: moderateParagraph }] } }))}</>)

    expect(screen.getAllByText("Show more")).toHaveLength(2)
  })

  it("shows every filter and returned metadata field without inventing private data", () => {
    const memory = {
      ...publishedRepoMemory,
      user_id: 17,
      source_type: "job",
      source_id: 91,
      author: "agent",
      confidence: 0.8,
      visibility: "repository",
      expires_at: "2027-01-01T00:00:00Z",
      last_verified_at: "2026-09-03T00:00:00Z",
      created_at: "2026-08-01T00:00:00Z",
      deleted_at: "2026-09-04T00:00:00Z",
      deleted_by_user_id: 23
    }
    render(
      <>{listMemoriesToolCard.renderExpanded(context({ input: { scope: "repository", kind: "decision", limit: 25 }, parsedResult: { memories: [memory] } }))}</>
    )

    expect(screen.getByText("Requested scope")).toBeInTheDocument()
    expect(screen.getByText("Requested kind")).toBeInTheDocument()
    expect(screen.getByText("Requested limit")).toBeInTheDocument()
    expect(screen.getAllByText("agent")).toHaveLength(2)
    expect(screen.getAllByText("17")).toHaveLength(2)
    expect(screen.getAllByText("job")).toHaveLength(2)
    expect(screen.getAllByRole("link", { name: /JOB-91/ })).toHaveLength(2)
    expect(screen.getAllByText("0.8")).toHaveLength(2)
    expect(screen.getAllByText("repository")).toHaveLength(3)
    expect(screen.getAllByText("2027-01-01T00:00:00Z")).toHaveLength(2)
    expect(screen.getAllByText("2026-09-03T00:00:00Z")).toHaveLength(2)
    expect(screen.getAllByText("2026-08-01T00:00:00Z")).toHaveLength(2)
    expect(screen.getAllByText("23")).toHaveLength(2)
  })

  it("renders pending and error states", () => {
    const pending = context()
    expect(listMemoriesToolCard.renderExpanded(pending)).not.toBeNull()
    const { rerender } = render(<>{listMemoriesToolCard.renderExpanded(pending)}</>)
    expect(screen.getByText("Loading memories...")).toBeInTheDocument()

    const failure = context({ resultBody: "Error: Memory provider unavailable.", resultError: true })
    expect(listMemoriesToolCard.collapsedSummary?.(failure)).toContain("Unable to list memories")
    rerender(<>{listMemoriesToolCard.renderExpanded(failure)}</>)
    expect(screen.getByRole("alert")).toHaveTextContent("Memory provider unavailable")
  })

  it("accepts provider-independent structured and text MCP envelopes", () => {
    const payload = { memories: [globalMemory] }
    for (const envelope of [{ structured_content: payload }, { content: [{ type: "text", text: JSON.stringify(payload) }] }]) {
      const parsedResult = normalizedToolCardParsedResult(envelope)
      expect(listMemoriesToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("1 memory")
    }
  })

  it("linkifies markdown slugs and URLs in expandable content", () => {
    const content = `See JOB-42 and https://example.test/docs. ${"More details. ".repeat(30)}`
    render(<MemoryRouter>{listMemoriesToolCard.renderExpanded(context({ parsedResult: { memories: [{ ...globalMemory, content }] } }))}</MemoryRouter>)

    expect(screen.getAllByRole("link", { name: "JOB-42" })).toHaveLength(2)
    expect(screen.getAllByRole("link", { name: "https://example.test/docs" })).toHaveLength(2)
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }

    expect(listMemoriesToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(listMemoriesToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"

    expect(listMemoriesToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(listMemoriesToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
