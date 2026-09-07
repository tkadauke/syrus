import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import listRepositoryTestInsightsToolCard from "./list_repository_test_insights"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "list_repository_test_insights",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const failingTest = {
  id: 42,
  suite_name: "FooSpec",
  name: "does something important",
  file_path: "spec/foo_spec.rb",
  last_status: "failed",
  failure_rate: 0.5,
  avg_duration_ms: 1500,
  last_duration_ms: 1200,
  interesting_reasons: ["failing", "slow"],
  links: { app_path: "/repositories/1?tab=tests&test_id=42" }
}

const flakyTest = {
  id: 43,
  suite_name: "BarSpec",
  name: "sometimes fails",
  file_path: "spec/bar_spec.rb",
  last_status: "passed",
  failure_rate: 0.3,
  avg_duration_ms: 200,
  last_duration_ms: 180,
  interesting_reasons: ["flaky"],
  links: { app_path: "/repositories/1?tab=tests&test_id=43" }
}

describe("list_repository_test_insights tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(listRepositoryTestInsightsToolCard.toolName).toBe("list_repository_test_insights")
  })

  it("summarizes the collapsed row with a test count", () => {
    expect(listRepositoryTestInsightsToolCard.collapsedSummary?.(context({ parsedResult: { tests: [failingTest, flakyTest] } }))).toBe("2 tests")
  })

  it("singularizes the collapsed summary for one test", () => {
    expect(listRepositoryTestInsightsToolCard.collapsedSummary?.(context({ parsedResult: { tests: [failingTest] } }))).toBe("1 test")
  })

  it("renders a dense table row with name, file, category, status, failure rate, and durations", () => {
    render(<>{listRepositoryTestInsightsToolCard.renderExpanded(context({ parsedResult: { tests: [failingTest] } }))}</>)

    const link = screen.getByRole("link", { name: "does something important" })
    expect(link).toHaveAttribute("href", "/repositories/1?tab=tests&test_id=42")
    expect(screen.getByText("spec/foo_spec.rb")).toBeInTheDocument()
    expect(screen.getByText("failing")).toBeInTheDocument()
    expect(screen.getByText("slow")).toBeInTheDocument()
    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("50%")).toBeInTheDocument()
    expect(screen.getByText("1.50s / 1.20s")).toBeInTheDocument()
  })

  it("flags a flaky test in the category column", () => {
    render(<>{listRepositoryTestInsightsToolCard.renderExpanded(context({ parsedResult: { tests: [flakyTest] } }))}</>)

    expect(screen.getByText("sometimes fails")).toBeInTheDocument()
    expect(screen.getByText("flaky")).toBeInTheDocument()
    expect(screen.getByText("30%")).toBeInTheDocument()
  })

  it("renders a friendly empty state for no tests", () => {
    render(<>{listRepositoryTestInsightsToolCard.renderExpanded(context({ parsedResult: { tests: [] } }))}</>)

    expect(screen.getByText("No tests match this query.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }

    expect(listRepositoryTestInsightsToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(listRepositoryTestInsightsToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"

    expect(listRepositoryTestInsightsToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(listRepositoryTestInsightsToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
