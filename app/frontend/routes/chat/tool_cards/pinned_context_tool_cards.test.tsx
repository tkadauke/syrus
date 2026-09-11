import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import removePinnedContextToolCard from "./remove_pinned_context"
import updatePinnedContextToolCard from "./update_pinned_context"

function context(toolName: string, overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName,
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("pinned context tool cards", () => {
  it("registers under the exact MCP tool names", () => {
    expect(updatePinnedContextToolCard.toolName).toBe("update_pinned_context")
    expect(removePinnedContextToolCard.toolName).toBe("remove_pinned_context")
  })

  it("renders updated pinned context with a concise preview", () => {
    const longContext = Array.from({ length: 30 }, (_, index) => `Line ${index + 1}: remember the OAuth migration detail.`).join("\n")
    const parsedResult = { pinned_context: longContext, message: "Pinned context updated." }

    expect(updatePinnedContextToolCard.collapsedSummary?.(context("update_pinned_context", { parsedResult }))).toBe("Pinned context updated.")
    render(<>{updatePinnedContextToolCard.renderExpanded(context("update_pinned_context", { parsedResult }))}</>)

    expect(screen.getByText("updated")).toBeInTheDocument()
    expect(screen.getByText("30")).toBeInTheDocument()
    expect(screen.getByText(String(longContext.length))).toBeInTheDocument()
    expect(screen.getByText("Context preview")).toBeInTheDocument()
    expect(screen.getByText(/Line 1: remember/)).toBeInTheDocument()
    expect(screen.getByText((content) => content === "Showing a concise preview of 30 lines.")).toBeInTheDocument()
    expect(screen.queryByText(/Line 30/)).not.toBeInTheDocument()
  })

  it("renders removed pinned context state", () => {
    const parsedResult = { pinned_context: null, message: "Pinned context removed." }

    expect(removePinnedContextToolCard.collapsedSummary?.(context("remove_pinned_context", { parsedResult }))).toBe("Pinned context removed.")
    render(<>{removePinnedContextToolCard.renderExpanded(context("remove_pinned_context", { parsedResult }))}</>)

    expect(screen.getByText("removed")).toBeInTheDocument()
    expect(screen.getByText("Pinned context removed.")).toBeInTheDocument()
    expect(screen.queryByText("Context preview")).not.toBeInTheDocument()
  })

  it("falls back to the generic renderer for malformed payloads", () => {
    expect(updatePinnedContextToolCard.collapsedSummary?.(context("update_pinned_context", { parsedResult: { oops: true } }))).toBeNull()
    expect(updatePinnedContextToolCard.renderExpanded(context("update_pinned_context", { parsedResult: "not json" }))).toBeNull()
    expect(removePinnedContextToolCard.renderExpanded(context("remove_pinned_context", { parsedResult: { pinned_context: 7 } }))).toBeNull()
  })
})
