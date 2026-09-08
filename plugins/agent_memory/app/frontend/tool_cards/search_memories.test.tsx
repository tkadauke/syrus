import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import searchMemoriesToolCard from "./search_memories"

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
  updated_at: "2026-08-20T09:00:00Z"
}

describe("search_memories tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(searchMemoriesToolCard.toolName).toBe("search_memories")
  })

  it("summarizes the collapsed row with a memory count", () => {
    expect(searchMemoriesToolCard.collapsedSummary?.(context({ parsedResult: { memories: [match] } }))).toBe("1 memory")
  })

  it("renders a private state pill for an unpublished repository memory", () => {
    render(<>{searchMemoriesToolCard.renderExpanded(context({ parsedResult: { memories: [match] } }))}</>)

    expect(screen.getByText("reference")).toBeInTheDocument()
    expect(screen.getByText("repository #5")).toBeInTheDocument()
    expect(screen.getByText("private")).toBeInTheDocument()
    expect(screen.getByText("Bugs tracked in Linear project INGEST.")).toBeInTheDocument()
  })

  it("renders a friendly empty state for no results", () => {
    render(<>{searchMemoriesToolCard.renderExpanded(context({ parsedResult: { memories: [] } }))}</>)

    expect(screen.getByText("No memories match this search.")).toBeInTheDocument()
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
