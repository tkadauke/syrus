import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import searchJobsToolCard from "./search_jobs"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "search_jobs",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("search_jobs tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(searchJobsToolCard.toolName).toBe("search_jobs")
  })

  it("summarizes the collapsed row with the total match count, not just the page size", () => {
    const parsedResult = { total: 37, results: [{ id: 1, state: "open" }] }
    expect(searchJobsToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("37 matching Jobs")
  })

  it("renders a dense table with one row per matching Job", () => {
    const parsedResult = {
      total: 1,
      results: [{ id: 4048, repository_slug: "tkadauke/syrus", issue_title: "Add tool cards", state: "running", pr_number: 12, priority: "high" }]
    }

    render(<>{searchJobsToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByRole("table")).toBeInTheDocument()
    expect(screen.getByText("JOB-4048")).toBeInTheDocument()
    expect(screen.getByText("Add tool cards")).toBeInTheDocument()
  })

  it("renders a friendly empty state for no matches", () => {
    render(<>{searchJobsToolCard.renderExpanded(context({ parsedResult: { total: 0, results: [] } }))}</>)
    expect(screen.getByText("No Jobs matched the search.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(searchJobsToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(searchJobsToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(searchJobsToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
