import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import writeMemoryToolCard from "./write_memory"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "write_memory",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const memory = {
  id: 55,
  kind: "feedback",
  scope: "global",
  scope_id: null,
  content: "Don't mock the database in integration tests.",
  published: false,
  updated_at: "2026-09-05T14:00:00Z"
}

describe("write_memory tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(writeMemoryToolCard.toolName).toBe("write_memory")
  })

  it("summarizes the collapsed row as a write confirmation", () => {
    expect(writeMemoryToolCard.collapsedSummary?.(context({ parsedResult: { id: 55, memory } }))).toBe("Wrote memory #55 (feedback)")
  })

  it("renders the written memory's content and kind", () => {
    render(<>{writeMemoryToolCard.renderExpanded(context({ parsedResult: { id: 55, memory } }))}</>)

    expect(screen.getByText("feedback")).toBeInTheDocument()
    expect(screen.getByText("Don't mock the database in integration tests.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }

    expect(writeMemoryToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(writeMemoryToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"

    expect(writeMemoryToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(writeMemoryToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
