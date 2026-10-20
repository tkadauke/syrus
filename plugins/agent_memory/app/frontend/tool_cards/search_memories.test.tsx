import { fireEvent, render, screen, within } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it } from "vitest"
import { MemoryRouter } from "react-router-dom"
import type { ToolCardContext } from "@app/pluginToolCards"
import { redactToolCardValue } from "@app/toolCardSecurity"
import { normalizedToolCardParsedResult } from "@app/routes/chat/toolRendering"
import { setSlugReferenceRegistryForTests } from "@app/lib/slugReferenceRegistry"
import searchMemoriesToolCard from "./search_memories"

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

afterEach(() => setSlugReferenceRegistryForTests(null))

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "search_memories",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const match = {
  id: 3,
  kind: "reference",
  scope: "repository",
  scope_id: 5,
  content: "Bugs tracked in Linear project INGEST.",
  published: false,
  author: "agent",
  confidence: 0.8,
  expires_at: "2027-01-01T00:00:00Z",
  last_verified_at: "2026-08-19T09:00:00Z",
  created_at: "2026-08-18T09:00:00Z",
  updated_at: "2026-08-20T09:00:00Z"
}

describe("search_memories tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(searchMemoriesToolCard.toolName).toBe("search_memories")
  })

  it("summarizes the collapsed row with a memory count", () => {
    expect(searchMemoriesToolCard.collapsedSummary?.(context({ parsedResult: { memories: [match] } }))).toBe("1 memory")
  })

  it("renders every search input and returned field in responsive stacked rows", () => {
    const { container } = render(
      <>
        {searchMemoriesToolCard.renderExpanded(
          context({ input: { query: "Linear", scope: "repository", kind: "reference", limit: 20 }, parsedResult: { memories: [match] } })
        )}
      </>
    )

    expect(screen.getByText("Query")).toBeInTheDocument()
    expect(screen.getAllByText("Linear")).toHaveLength(2)
    expect(screen.getByText("Requested scope")).toBeInTheDocument()
    expect(screen.getByText("Limit")).toBeInTheDocument()
    expect(screen.getByText("20")).toBeInTheDocument()
    expect(screen.getAllByText("reference")).toHaveLength(2)
    expect(screen.getByRole("link", { name: /MEMORY-3/ })).toHaveAttribute("href", "/memories")
    expect(screen.getByRole("link", { name: /repository #5/i })).toHaveAttribute("href", "/repositories/5")
    expect(screen.getByText("private")).toBeInTheDocument()
    expect(screen.getByText("agent")).toBeInTheDocument()
    expect(screen.getByText("0.8")).toBeInTheDocument()
    for (const timestamp of ["2027-01-01T00:00:00Z", "2026-08-19T09:00:00Z", "2026-08-18T09:00:00Z", "2026-08-20T09:00:00Z"]) {
      expect(screen.getByText(timestamp)).toBeInTheDocument()
    }
    expect(container.querySelector("table")).not.toBeInTheDocument()
    expect(container.querySelector("article.min-w-0")).toHaveClass("p-3")
  })

  it("highlights the case-insensitive query while preserving markdown, links, and Show more", () => {
    const content = `Use **Linear** with JOB-42 and https://example.com/guide. ${"More searchable content. ".repeat(12)}`
    const { container } = render(
      <MemoryRouter>
        {searchMemoriesToolCard.renderExpanded(context({ input: { query: "linear" }, parsedResult: { memories: [{ ...match, content }] } }))}
      </MemoryRouter>
    )

    expect(container.querySelector("mark[data-search-highlight]")).toHaveTextContent("Linear")
    expect(screen.getByRole("link", { name: "JOB-42" })).toHaveAttribute("href", "/jobs/42")
    expect(screen.getByRole("link", { name: "https://example.com/guide" })).toHaveAttribute("href", "https://example.com/guide")
    fireEvent.click(screen.getByText("Show more"))
    expect(within(screen.getByRole("dialog")).getByText(/More searchable content/)).toBeInTheDocument()
  })

  it("includes the query in the localized empty state", () => {
    render(<>{searchMemoriesToolCard.renderExpanded(context({ input: { query: "missing phrase" }, parsedResult: { memories: [] } }))}</>)

    expect(screen.getByText("No memories match “missing phrase”.")).toBeInTheDocument()
  })

  it("renders pending and error states with the attempted inputs", () => {
    const pending = context({ input: { query: "Linear", kind: "reference", limit: 5 } })
    expect(searchMemoriesToolCard.collapsedSummary?.(pending)).toBe("Searching memories for “Linear”")
    const { rerender } = render(<>{searchMemoriesToolCard.renderExpanded(pending)}</>)
    expect(screen.getByText("Searching memories for “Linear”…")).toBeInTheDocument()

    const failed = context({ input: { query: "Linear" }, resultBody: "Error: service unavailable", resultError: true })
    expect(searchMemoriesToolCard.collapsedSummary?.(failed)).toBe("Memory search for “Linear” failed")
    rerender(<>{searchMemoriesToolCard.renderExpanded(failed)}</>)
    expect(screen.getByRole("alert")).toHaveTextContent("service unavailable")
    expect(screen.getByRole("alert")).toHaveTextContent("Memory search failed")
  })

  it("accepts provider-agnostic result envelopes and keeps redaction at the shared boundary", () => {
    const payload = { memories: [match] }
    for (const envelope of [payload, { structured_content: payload }, { content: [{ type: "text", text: JSON.stringify(payload) }] }]) {
      const parsedResult = normalizedToolCardParsedResult(redactToolCardValue(envelope))
      expect(searchMemoriesToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("1 memory")
    }

    const redacted = normalizedToolCardParsedResult(redactToolCardValue({ memories: [{ ...match, content: "password=hunter2-secret" }] }))
    render(<>{searchMemoriesToolCard.renderExpanded(context({ input: { query: "password" }, parsedResult: redacted }))}</>)
    expect(screen.getByTestId("markdown-preview-content")).toHaveTextContent("password=[redacted]")
    expect(screen.queryByText(/hunter2-secret/)).not.toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }

    expect(searchMemoriesToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(searchMemoriesToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"

    expect(searchMemoriesToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(searchMemoriesToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
