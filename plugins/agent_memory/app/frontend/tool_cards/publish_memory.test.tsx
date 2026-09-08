import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import publishMemoryToolCard from "./publish_memory"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "publish_memory",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const memory = {
  id: 20,
  kind: "decision",
  scope: "repository",
  scope_id: 3,
  content: "Ship weekly.",
  published: true,
  updated_at: "2026-09-01T00:00:00Z"
}

describe("publish_memory tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(publishMemoryToolCard.toolName).toBe("publish_memory")
  })

  it("summarizes the collapsed row as a publish confirmation", () => {
    expect(publishMemoryToolCard.collapsedSummary?.(context({ parsedResult: { memory } }))).toBe("Published memory #20")
  })

  it("renders the published pill", () => {
    render(<>{publishMemoryToolCard.renderExpanded(context({ parsedResult: { memory } }))}</>)

    expect(screen.getByText("published")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }

    expect(publishMemoryToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(publishMemoryToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
