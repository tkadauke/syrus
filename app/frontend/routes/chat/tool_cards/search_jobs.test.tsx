import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { toolResultPresentation } from "../toolRendering"
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

  it("is selected for an MCP-prefixed tool name", () => {
    const body = JSON.stringify({ total: 1, results: [{ id: 1, state: "open" }] })
    expect(toolResultPresentation("mcp__syrus-chat-sidecar__search_jobs", body)).toMatchObject({ summary: "1 matching Job" })
  })

  it("summarizes the collapsed row with the total match count, not just the page size", () => {
    const parsedResult = { total: 37, results: [{ id: 1, state: "open" }] }
    expect(searchJobsToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("37 matching Jobs")
  })

  it.each([
    { payload: [{ id: 1, state: "open" }] },
    { payload: { structured_content: { total: 37, results: [{ id: 1, state: "open" }] } } },
    { payload: { content: [{ type: "text", text: JSON.stringify({ total: 37, results: [{ id: 1, state: "open" }] }) }] } }
  ])("accepts alternate MCP envelopes", ({ payload: parsedResult }) => {
    const expected = Array.isArray(parsedResult) ? "1 matching Job" : "37 matching Jobs"
    expect(searchJobsToolCard.collapsedSummary?.(context({ parsedResult }))).toBe(expected)
  })

  it("renders a dense table with one row per matching Job", () => {
    const parsedResult = {
      total: 1,
      results: [{ id: 4048, repository_slug: "tkadauke/syrus", issue_title: "Add tool cards", state: "running", pr_number: 12, priority: "high" }]
    }

    render(<>{searchJobsToolCard.renderExpanded(context({ input: { query: "tool cards", state: "running", limit: 10 }, parsedResult }))}</>)

    expect(screen.getByRole("table")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-4048" })).toHaveAttribute("href", "/jobs/4048")
    expect(screen.getByText("Add tool cards")).toBeInTheDocument()
    expect(screen.getByText(/Showing 1 of 1/)).toHaveTextContent("Showing 1 of 1 · Query: tool cards · State: running · Ordered by most recently updated")
  })

  it("renders a friendly empty state for no matches", () => {
    render(<>{searchJobsToolCard.renderExpanded(context({ input: { query: "missing" }, parsedResult: { total: 0, results: [] } }))}</>)
    expect(screen.getByText(/Showing 0 of 0/)).toHaveTextContent("Query: missing · State: any")
    expect(screen.getByText("No Jobs matched the search.")).toBeInTheDocument()
  })

  it("renders tool errors with the requested search context", () => {
    render(
      <>{searchJobsToolCard.renderExpanded(context({ input: { query: "broken", state: "failed" }, resultBody: "Error: unavailable", resultError: true }))}</>
    )
    expect(screen.getByText(/Query: broken/)).toHaveTextContent("State: failed · Ordered by most recently updated")
    expect(screen.getByText("Error: unavailable")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(searchJobsToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(searchJobsToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(searchJobsToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
