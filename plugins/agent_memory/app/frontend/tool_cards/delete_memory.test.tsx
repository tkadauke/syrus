import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import deleteMemoryToolCard from "./delete_memory"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "delete_memory",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("delete_memory tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(deleteMemoryToolCard.toolName).toBe("delete_memory")
  })

  it("summarizes the collapsed row with a deletion confirmation", () => {
    expect(deleteMemoryToolCard.collapsedSummary?.(context({ parsedResult: { id: 9, deleted: true } }))).toBe("Deleted memory #9")
  })

  it("renders the memory id and deleted status", () => {
    render(<>{deleteMemoryToolCard.renderExpanded(context({ parsedResult: { id: 9, deleted: true } }))}</>)

    expect(screen.getByText("9")).toBeInTheDocument()
    expect(screen.getByText("Deleted")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }

    expect(deleteMemoryToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(deleteMemoryToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"

    expect(deleteMemoryToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(deleteMemoryToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
