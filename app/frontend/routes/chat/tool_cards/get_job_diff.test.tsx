import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import getJobDiffToolCard from "./get_job_diff"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "get_job_diff",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("get_job_diff tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(getJobDiffToolCard.toolName).toBe("get_job_diff")
  })

  it("summarizes the collapsed row with page info", () => {
    const parsedResult = { job_id: 4221, run_id: 9, diff: "diff --git a/x b/x\n+a", page: 1, total_pages: 2, has_next_page: true }
    expect(getJobDiffToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("JOB-4221 diff (page 1 of 2)")
  })

  it("summarizes the collapsed row when there is no stored diff", () => {
    const parsedResult = { job_id: 4221, run_id: null, diff: null, page: 1, total_pages: 0, total_bytes: 0, has_next_page: false, message: "No stored diff is available for this Job yet." }
    expect(getJobDiffToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("JOB-4221: no stored diff")
  })

  it("renders the no-diff message when diff is null", () => {
    const parsedResult = { job_id: 4221, run_id: null, diff: null, page: 1, total_pages: 0, total_bytes: 0, has_next_page: false, message: "No stored diff is available for this Job yet." }
    render(<>{getJobDiffToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("JOB-4221")).toBeInTheDocument()
    expect(screen.getByText("No stored diff is available for this Job yet.")).toBeInTheDocument()
  })

  it("renders diff stats, pagination, and a raw diff preview", () => {
    const parsedResult = {
      job_id: 4221,
      run_id: 9,
      diff: "diff --git a/foo.rb b/foo.rb\n+added\n-removed",
      page: 1,
      per_bytes: 51200,
      total_bytes: 640020,
      total_pages: 13,
      has_next_page: true,
      next_page: 2
    }

    render(<>{getJobDiffToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("JOB-4221")).toBeInTheDocument()
    expect(screen.getByText("RUN-9")).toBeInTheDocument()
    expect(screen.getByText("1 file")).toBeInTheDocument()
    expect(screen.getByText("+1")).toBeInTheDocument()
    expect(screen.getByText("-1")).toBeInTheDocument()
    expect(screen.getByText("1 of 13 (more available)")).toBeInTheDocument()
    expect(screen.getByText("640020")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload (missing job_id)", () => {
    expect(getJobDiffToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(getJobDiffToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(getJobDiffToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
