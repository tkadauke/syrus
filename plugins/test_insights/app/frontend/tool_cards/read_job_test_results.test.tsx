import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import readJobTestResultsToolCard from "./read_job_test_results"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "read_job_test_results",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const testRun = {
  id: 1,
  grader_name: "rspec",
  total_count: 10,
  passed_count: 7,
  failed_count: 2,
  skipped_count: 0,
  error_count: 1,
  duration_ms: 4200,
  failed_error_cases: [
    {
      id: 100,
      name: "handles the edge case",
      suite_name: "ASpec",
      status: "failed",
      duration_ms: 300,
      test_identity_id: 42,
      flakiness: { score: 0.6, flaky: true },
      failure: { message: "expected true to be false", backtrace: "spec/a_spec.rb:10", output: null }
    }
  ],
  failed_error_case_count: 3,
  failed_error_cases_omitted: 2,
  slow_cases: [{ id: 101, name: "a rather slow test", suite_name: "BSpec", status: "passed", duration_ms: 5000, test_identity_id: 43, flakiness: null }],
  slow_case_count: 1,
  slow_cases_omitted: 0
}

describe("read_job_test_results tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(readJobTestResultsToolCard.toolName).toBe("read_job_test_results")
  })

  it("summarizes the collapsed row with the job slug and failure counts", () => {
    const parsedResult = { job_id: 10, job_slug: "JOB-10", run_id: null, grader_name: null, test_runs: [testRun] }

    expect(readJobTestResultsToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("JOB-10: 3 failed of 10 across 1 grader")
  })

  it("renders suite totals, grader name, and job reference", () => {
    const parsedResult = { job_id: 10, job_slug: "JOB-10", run_id: null, grader_name: null, test_runs: [testRun] }
    render(<>{readJobTestResultsToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("JOB-10")).toBeInTheDocument()
    expect(screen.getByText("rspec")).toBeInTheDocument()
    expect(screen.getByText("7 passed · 2 failed · 1 errors · 0 skipped")).toBeInTheDocument()
  })

  it("renders failed/error cases with failure snippets and flakiness", () => {
    const parsedResult = { job_id: 10, job_slug: "JOB-10", run_id: null, grader_name: null, test_runs: [testRun] }
    render(<>{readJobTestResultsToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("Failed / error cases (2 more omitted)")).toBeInTheDocument()
    expect(screen.getByText(/handles the edge case/)).toBeInTheDocument()
    expect(screen.getByText("expected true to be false")).toBeInTheDocument()
    expect(screen.getByText("flaky (60%)")).toBeInTheDocument()
  })

  it("renders slow cases in their own section", () => {
    const parsedResult = { job_id: 10, job_slug: "JOB-10", run_id: null, grader_name: null, test_runs: [testRun] }
    render(<>{readJobTestResultsToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("Slow cases")).toBeInTheDocument()
    expect(screen.getByText(/a rather slow test/)).toBeInTheDocument()
  })

  it("renders a friendly empty state when the job has no test results yet", () => {
    const parsedResult = { job_id: 10, job_slug: "JOB-10", run_id: null, grader_name: null, test_runs: [] }
    render(<>{readJobTestResultsToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("No test results recorded yet.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }

    expect(readJobTestResultsToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(readJobTestResultsToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"

    expect(readJobTestResultsToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
