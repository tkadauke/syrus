import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import writeFileToolCard from "./write_file"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "write_file", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("write_file tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(writeFileToolCard.toolName).toBe("write_file")
  })

  it("summarizes the collapsed row generically (no input available there)", () => {
    expect(writeFileToolCard.collapsedSummary?.(context({ parsedResult: { success: true } }))).toBe("Wrote file")
  })

  it("renders the path and line count from the tool call input", () => {
    render(
      <>
        {writeFileToolCard.renderExpanded(
          context({
            parsedResult: { success: true },
            input: { path: "app/models/job.rb", content: "line1\nline2\nline3" }
          })
        )}
      </>
    )

    expect(screen.getByText("app/models/job.rb")).toBeInTheDocument()
    expect(screen.getByText("3")).toBeInTheDocument()
    expect(screen.getByText("Written content")).toBeInTheDocument()
    expect(screen.queryByText("line1")).not.toBeInTheDocument()
  })

  it("renders without the content disclosure when input is unavailable", () => {
    render(<>{writeFileToolCard.renderExpanded(context({ parsedResult: { success: true } }))}</>)
    expect(screen.queryByText("Written content")).not.toBeInTheDocument()
  })

  it("falls back to null when the tool did not succeed", () => {
    expect(writeFileToolCard.collapsedSummary?.(context({ parsedResult: { error: "denied" } }))).toBeNull()
    expect(writeFileToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
