import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import compareTestRuntimeToolCard from "./compare_test_runtime"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "compare_test_runtime",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const baseline = { type: "run", label: "baseline", run_id: 100, run_slug: "RUN-100", job_id: 5, job_slug: "JOB-5" }
const comparison = { type: "run", label: "comparison", run_id: 101, run_slug: "RUN-101", job_id: 5, job_slug: "JOB-5" }

const regressedTest = {
  test: { id: 42, suite_name: "FooSpec", name: "regressed test", file_path: "spec/foo_spec.rb", links: { app_path: "/repositories/1?tab=tests&test_id=42" } },
  baseline: { sample_count: 10, avg_duration_ms: 1000, p50_duration_ms: 950, p95_duration_ms: 1200, latest_duration_ms: 1000 },
  comparison: { sample_count: 10, avg_duration_ms: 1500, p50_duration_ms: 1400, p95_duration_ms: 1800, latest_duration_ms: 1500 },
  delta: { avg_duration_ms: { ms: 500, percent: 50.0 }, sample_count: 0 }
}

const improvedTest = {
  test: { id: 43, suite_name: "BarSpec", name: "improved test", file_path: "spec/bar_spec.rb", links: { app_path: "/repositories/1?tab=tests&test_id=43" } },
  baseline: { sample_count: 5, avg_duration_ms: 2000, p50_duration_ms: 2000, p95_duration_ms: 2000, latest_duration_ms: 2000 },
  comparison: { sample_count: 5, avg_duration_ms: 1000, p50_duration_ms: 1000, p95_duration_ms: 1000, latest_duration_ms: 1000 },
  delta: { avg_duration_ms: { ms: -1000, percent: -50.0 }, sample_count: 0 }
}

describe("compare_test_runtime tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(compareTestRuntimeToolCard.toolName).toBe("compare_test_runtime")
  })

  it("summarizes the collapsed row with a test count and source labels", () => {
    const parsedResult = { grader_name: "rspec", baseline, comparison, tests: [regressedTest, improvedTest] }

    expect(compareTestRuntimeToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("2 tests: RUN-100 vs RUN-101")
  })

  it("renders baseline/comparison source badges and per-test avg/p95 durations", () => {
    const parsedResult = { grader_name: "rspec", baseline, comparison, tests: [regressedTest] }
    render(<>{compareTestRuntimeToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("baseline: RUN-100")).toBeInTheDocument()
    expect(screen.getByText("comparison: RUN-101")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "regressed test" })).toHaveAttribute("href", "/repositories/1?tab=tests&test_id=42")
    expect(screen.getByText("1.00s / 1.20s")).toBeInTheDocument()
    expect(screen.getByText("1.50s / 1.80s")).toBeInTheDocument()
  })

  it("highlights a regression as slower", () => {
    const parsedResult = { grader_name: "rspec", baseline, comparison, tests: [regressedTest] }
    render(<>{compareTestRuntimeToolCard.renderExpanded(context({ parsedResult }))}</>)

    const delta = screen.getByText("+500ms (+50%)")
    expect(delta).toBeInTheDocument()
    expect(delta.className).toContain("text-red-700")
  })

  it("highlights an improvement as faster", () => {
    const parsedResult = { grader_name: "rspec", baseline, comparison, tests: [improvedTest] }
    render(<>{compareTestRuntimeToolCard.renderExpanded(context({ parsedResult }))}</>)

    const delta = screen.getByText("-1000ms (-50%)")
    expect(delta).toBeInTheDocument()
    expect(delta.className).toContain("text-emerald-700")
  })

  it("renders a friendly empty state for no matching tests", () => {
    const parsedResult = { grader_name: "rspec", baseline, comparison, tests: [] }
    render(<>{compareTestRuntimeToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("No matching tests to compare.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }

    expect(compareTestRuntimeToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(compareTestRuntimeToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"

    expect(compareTestRuntimeToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
