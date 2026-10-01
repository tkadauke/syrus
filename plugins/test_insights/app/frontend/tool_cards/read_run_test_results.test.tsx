import { fireEvent, render, screen } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import readRunTestResultsToolCard from "./read_run_test_results"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "read_run_test_results",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const testRun = {
  id: 1,
  grader_name: "jest",
  total_count: 4,
  passed_count: 4,
  failed_count: 0,
  skipped_count: 0,
  error_count: 0,
  duration_ms: 900,
  failed_error_cases: [],
  failed_error_case_count: 0,
  failed_error_cases_omitted: 0,
  slow_cases: [],
  slow_case_count: 0,
  slow_cases_omitted: 0
}

describe("read_run_test_results tool card", () => {
  beforeEach(() => {
    Object.assign(navigator, {
      clipboard: { writeText: vi.fn().mockResolvedValue(undefined) }
    })
  })

  it("registers under the exact MCP tool name", () => {
    expect(readRunTestResultsToolCard.toolName).toBe("read_run_test_results")
  })

  it("summarizes the collapsed row with the run id and failure counts", () => {
    const parsedResult = { job_id: 10, job_slug: "JOB-10", workflow_id: 30, run_id: 200, grader_name: "jest", test_runs: [testRun] }

    expect(readRunTestResultsToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("RUN-200: 0 failed of 4 across 1 grader")
  })

  it("renders the run reference and suite totals", () => {
    const parsedResult = { job_id: 10, job_slug: "JOB-10", workflow_id: 30, run_id: 200, grader_name: "jest", test_runs: [testRun] }
    render(<>{readRunTestResultsToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByRole("link", { name: "RUN-200" })).toHaveAttribute("href", "/jobs/10?tab=workflows#workflow-30")
    expect(screen.getByRole("link", { name: "JOB-10" })).toHaveAttribute("href", "/jobs/10")
    fireEvent.click(screen.getByRole("button", { name: "Copy RUN-200 to clipboard" }))
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith("RUN-200")
    expect(screen.getByText("4 passed · 0 failed · 0 errors · 0 skipped")).toBeInTheDocument()
  })

  it("renders a friendly empty state when the run has no test results", () => {
    const parsedResult = { job_id: 10, job_slug: "JOB-10", run_id: 200, grader_name: null, test_runs: [] }
    render(<>{readRunTestResultsToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("No test results recorded yet.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }

    expect(readRunTestResultsToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(readRunTestResultsToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"

    expect(readRunTestResultsToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
