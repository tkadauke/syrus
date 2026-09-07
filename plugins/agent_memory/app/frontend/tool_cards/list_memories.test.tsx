import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
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

  it("renders kind, scope, content preview, and updated_at for a global memory", () => {
    render(<>{listMemoriesToolCard.renderExpanded(context({ parsedResult: { memories: [globalMemory] } }))}</>)

    expect(screen.getByText("user pref")).toBeInTheDocument()
    expect(screen.getByText("global")).toBeInTheDocument()
    expect(screen.getByText("Prefers terse responses.")).toBeInTheDocument()
    expect(screen.getByText("2026-09-01T12:00:00Z")).toBeInTheDocument()
    expect(screen.queryByText("published")).not.toBeInTheDocument()
    expect(screen.queryByText("private")).not.toBeInTheDocument()
  })

  it("shows a published pill and repository scope for a published repository memory", () => {
    render(<>{listMemoriesToolCard.renderExpanded(context({ parsedResult: { memories: [publishedRepoMemory] } }))}</>)

    expect(screen.getByText("decision")).toBeInTheDocument()
    expect(screen.getByText("repository #42")).toBeInTheDocument()
    expect(screen.getByText("published")).toBeInTheDocument()
  })

  it("renders a friendly empty state for no memories", () => {
    render(<>{listMemoriesToolCard.renderExpanded(context({ parsedResult: { memories: [] } }))}</>)

    expect(screen.getByText("No memories match this scope.")).toBeInTheDocument()
  })

  it("truncates long content behind a disclosure", () => {
    const longContent = Array.from({ length: 10 }, (_, i) => `line ${i}`).join("\n")
    render(<>{listMemoriesToolCard.renderExpanded(context({ parsedResult: { memories: [{ ...globalMemory, content: longContent }] } }))}</>)

    expect(screen.getByText("Show full content (10 lines)")).toBeInTheDocument()
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
