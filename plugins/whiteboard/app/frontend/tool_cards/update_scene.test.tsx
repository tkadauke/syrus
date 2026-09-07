import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import updateSceneToolCard from "./update_scene"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "update_scene",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("update_scene tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(updateSceneToolCard.toolName).toBe("update_scene")
  })

  it("summarizes the collapsed row using the replacement element count from input", () => {
    const input = { elements: [{ id: "a" }, { id: "b" }, { id: "c" }] }
    const parsedResult = { replaced: true, version: 5 }
    expect(updateSceneToolCard.collapsedSummary?.(context({ input, parsedResult }))).toBe("Replaced scene: 3 elements")
  })

  it("renders the replacement counts", () => {
    const input = { elements: [{ id: "a" }], files: { f1: {} } }
    const parsedResult = { replaced: true, version: 2 }
    render(<>{updateSceneToolCard.renderExpanded(context({ input, parsedResult }))}</>)

    expect(screen.getByText("Replaced scene")).toBeInTheDocument()
    expect(screen.getByText("v2")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload (replaced not true)", () => {
    expect(updateSceneToolCard.renderExpanded(context({ parsedResult: { replaced: false } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(updateSceneToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })

  it("falls back to null instead of fabricating '0 elements' when input is absent (the collapsed-row dispatch case)", () => {
    // Collapsed-row dispatch never carries `input` (see toolRendering.ts's
    // toolResultPresentation) -- only the expanded view gets it. Without a
    // real input this card has no counts to report and must not claim
    // "0 elements", which would misrepresent every real replacement.
    const parsedResult = { replaced: true, version: 5 }
    expect(updateSceneToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(updateSceneToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
