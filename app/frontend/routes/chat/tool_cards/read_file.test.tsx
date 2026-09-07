import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import readFileToolCard from "./read_file"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "read_file", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("read_file tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(readFileToolCard.toolName).toBe("read_file")
  })

  it("summarizes the collapsed row with a line count", () => {
    const parsedResult = { content: "line1\nline2\nline3" }
    expect(readFileToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Read file (3 lines)")
  })

  it("renders the path from the tool call input plus the line count, without exposing content by default", () => {
    const parsedResult = { content: "line1\nline2" }
    render(<>{readFileToolCard.renderExpanded(context({ parsedResult, input: { path: "app/models/job.rb" } }))}</>)

    expect(screen.getByText("app/models/job.rb")).toBeInTheDocument()
    expect(screen.getByText("2")).toBeInTheDocument()
    expect(screen.queryByText("line1")).not.toBeInTheDocument()
    expect(screen.getByText("File content")).toBeInTheDocument()
  })

  it("truncates very large files behind the content disclosure", () => {
    const content = Array.from({ length: 500 }, (_, i) => `line ${i}`).join("\n")
    render(<>{readFileToolCard.renderExpanded(context({ parsedResult: { content } }))}</>)
    expect(screen.getByText("Showing first 200 of 500 lines.")).toBeInTheDocument()
  })

  it("handles an empty file", () => {
    render(<>{readFileToolCard.renderExpanded(context({ parsedResult: { content: "" } }))}</>)
    expect(screen.getByText("Empty file.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(readFileToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(readFileToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
