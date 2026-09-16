import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import setBookmarkToolCard from "./set_bookmark"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "set_bookmark",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("set_bookmark tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(setBookmarkToolCard.toolName).toBe("set_bookmark")
  })

  it("summarizes the collapsed row with the label and kind", () => {
    const parsedResult = { id: 4, label: "Launch notes", kind: "topic", message_id: 12, anchor: "message-12" }
    expect(setBookmarkToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Bookmark added: Launch notes (topic)")
  })

  it("renders label, kind, anchor, and message id on success", () => {
    const parsedResult = { id: 4, label: "Launch notes", kind: "topic", message_id: 12, anchor: "message-12" }
    render(<>{setBookmarkToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("added")).toBeInTheDocument()
    expect(screen.getByText("topic")).toBeInTheDocument()
    expect(screen.getByText("#4")).toBeInTheDocument()
    expect(screen.getByText("Launch notes")).toBeInTheDocument()
    expect(screen.getByText("message-12")).toBeInTheDocument()
    expect(screen.getByText("#12")).toBeInTheDocument()
  })

  it("omits optional id/kind/anchor/message fields when absent", () => {
    render(<>{setBookmarkToolCard.renderExpanded(context({ parsedResult: { label: "Untitled shift" } }))}</>)

    expect(screen.getByText("Untitled shift")).toBeInTheDocument()
    expect(screen.queryByText(/^#/)).not.toBeInTheDocument()
  })

  it("falls back to null for a malformed or error payload", () => {
    expect(setBookmarkToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(setBookmarkToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
    expect(setBookmarkToolCard.renderExpanded(context({ resultError: true, parsedResult: null, resultBody: "Error: label is required" }))).toBeNull()
  })
})
