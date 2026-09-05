import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import listJobsToolCard from "./list_jobs"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "list_jobs",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("list_jobs tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(listJobsToolCard.toolName).toBe("list_jobs")
  })

  it("summarizes the collapsed row with a Job count", () => {
    const parsedResult = { jobs: [{ id: 1, state: "open" }, { id: 2, state: "closed" }] }
    expect(listJobsToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("2 Jobs")
  })

  it("renders a dense table with one row per Job", () => {
    const parsedResult = {
      jobs: [
        { id: 4048, repository_slug: "tkadauke/syrus", issue_title: "Add tool cards", state: "running", pr_number: 12, priority: "high" },
        { id: 4049, repository_slug: "tkadauke/syrus", issue_title: "Fix bug", state: "queued", pr_number: null, priority: "medium" }
      ]
    }

    render(<>{listJobsToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByRole("table")).toBeInTheDocument()
    expect(screen.getByText("JOB-4048")).toBeInTheDocument()
    expect(screen.getByText("Add tool cards")).toBeInTheDocument()
    expect(screen.getByText("#12")).toBeInTheDocument()
    expect(screen.getByText("JOB-4049")).toBeInTheDocument()
    expect(screen.getByText("Fix bug")).toBeInTheDocument()
  })

  it("renders a friendly empty state for a well-formed empty list", () => {
    render(<>{listJobsToolCard.renderExpanded(context({ parsedResult: { jobs: [] } }))}</>)
    expect(screen.getByText("No Jobs found.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(listJobsToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(listJobsToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(listJobsToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
