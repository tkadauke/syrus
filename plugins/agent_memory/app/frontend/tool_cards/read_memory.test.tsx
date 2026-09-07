import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import readMemoryToolCard from "./read_memory"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "read_memory",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const memory = {
  id: 12,
  kind: "project_fact",
  scope: "repository",
  scope_id: 9,
  content: "Deploys SIGKILL in-flight Runs.",
  published: true,
  author: "agent",
  confidence: 0.9,
  updated_at: "2026-08-31T10:15:00Z"
}

describe("read_memory tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(readMemoryToolCard.toolName).toBe("read_memory")
  })

  it("summarizes the collapsed row with id and kind", () => {
    expect(readMemoryToolCard.collapsedSummary?.(context({ parsedResult: { memory } }))).toBe("Memory #12 (project_fact)")
  })

  it("renders kind, scope, published state, author, confidence, and content", () => {
    render(<>{readMemoryToolCard.renderExpanded(context({ parsedResult: { memory } }))}</>)

    expect(screen.getByText("project fact")).toBeInTheDocument()
    expect(screen.getByText("repository #9")).toBeInTheDocument()
    expect(screen.getByText("published")).toBeInTheDocument()
    expect(screen.getByText("agent")).toBeInTheDocument()
    expect(screen.getByText("0.9")).toBeInTheDocument()
    expect(screen.getByText("Deploys SIGKILL in-flight Runs.")).toBeInTheDocument()
  })

  it("shows a deleted pill for a soft-deleted memory", () => {
    render(<>{readMemoryToolCard.renderExpanded(context({ parsedResult: { memory: { ...memory, deleted_at: "2026-09-01T00:00:00Z" } } }))}</>)

    expect(screen.getByText("deleted")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }

    expect(readMemoryToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(readMemoryToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"

    expect(readMemoryToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(readMemoryToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
