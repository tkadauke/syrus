import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import readSceneToolCard from "./read_scene"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "read_scene",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("read_scene tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(readSceneToolCard.toolName).toBe("read_scene")
  })

  it("summarizes the collapsed row with element and file counts", () => {
    const parsedResult = { elements: [{ id: "a" }, { id: "b" }], appState: {}, files: { f1: {} }, version: 3 }
    expect(readSceneToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("2 elements, 1 file")
  })

  it("renders scene counts", () => {
    const parsedResult = { elements: [{ id: "a" }], appState: {}, files: {}, version: 1 }
    render(<>{readSceneToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("Scene")).toBeInTheDocument()
    expect(screen.getByText("v1")).toBeInTheDocument()
    expect(screen.getByText("1")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload (missing elements array)", () => {
    expect(readSceneToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(readSceneToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
