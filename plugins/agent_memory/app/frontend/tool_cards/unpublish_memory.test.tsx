import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import unpublishMemoryToolCard from "./unpublish_memory"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "unpublish_memory",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const memory = {
  id: 21,
  kind: "decision",
  scope: "repository",
  scope_id: 3,
  content: "Withdraw the rollout.",
  published: false,
  updated_at: "2026-09-01T00:00:00Z"
}

describe("unpublish_memory tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(unpublishMemoryToolCard.toolName).toBe("unpublish_memory")
  })

  it("summarizes the collapsed row as an unpublish confirmation", () => {
    expect(unpublishMemoryToolCard.collapsedSummary?.(context({ parsedResult: { memory } }))).toBe("Unpublished memory #21")
  })

  it("renders the private pill", () => {
    render(<>{unpublishMemoryToolCard.renderExpanded(context({ parsedResult: { memory } }))}</>)

    expect(screen.getByText("private")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }

    expect(unpublishMemoryToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(unpublishMemoryToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
