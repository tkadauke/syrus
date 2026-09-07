import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import readTestInsightToolCard from "./read_test_insight"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "read_test_insight",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const test = {
  id: 42,
  suite_name: "FooSpec",
  name: "does something important",
  file_path: "spec/foo_spec.rb",
  fingerprint: "abcdef1234567890",
  last_status: "failed",
  failure_rate: 0.4,
  avg_duration_ms: 800,
  recent_failure_count: 2,
  recent_pass_count: 3,
  recent_total_count: 5,
  reasons: ["failing", "flaky"],
  links: { app_path: "/repositories/1?tab=tests&test_id=42" }
}

const historyEntry = {
  test_case: { id: 901, status: "failed", duration_ms: 950, created_at: "2026-09-06T12:00:00Z" },
  test_run: { id: 55, grader_name: "rspec" },
  run: { id: 200, slug: "RUN-200", path: "/jobs/10?tab=workflows#run-200" },
  job: { id: 10, slug: "JOB-10", title: "Fix thing", path: "/jobs/10" },
  failure: { message: "expected true to be false", backtrace: "spec/foo_spec.rb:12:in `block'", output: null }
}

describe("read_test_insight tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(readTestInsightToolCard.toolName).toBe("read_test_insight")
  })

  it("summarizes the collapsed row with the test name and status", () => {
    expect(readTestInsightToolCard.collapsedSummary?.(context({ parsedResult: { test, history: [] } }))).toBe(
      "does something important (failed)"
    )
  })

  it("renders actionable identifiers, flaky/slow evidence, and recent record", () => {
    render(<>{readTestInsightToolCard.renderExpanded(context({ parsedResult: { test, history_limit: 25, history: [] } }))}</>)

    const link = screen.getByRole("link", { name: "does something important" })
    expect(link).toHaveAttribute("href", "/repositories/1?tab=tests&test_id=42")
    expect(screen.getByText("failing")).toBeInTheDocument()
    expect(screen.getByText("flaky")).toBeInTheDocument()
    expect(screen.getByText("42")).toBeInTheDocument()
    expect(screen.getByText("abcdef123456")).toBeInTheDocument()
    expect(screen.getByText("40%")).toBeInTheDocument()
    expect(screen.getByText("2 failed / 3 passed of 5")).toBeInTheDocument()
  })

  it("renders recent executions with a run/job link and failure snippet", () => {
    render(<>{readTestInsightToolCard.renderExpanded(context({ parsedResult: { test, history_limit: 25, history: [historyEntry] } }))}</>)

    expect(screen.getByText("Recent executions (up to 25)")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "RUN-200" })).toHaveAttribute("href", "/jobs/10?tab=workflows#run-200")
    expect(screen.getByRole("link", { name: "JOB-10" })).toHaveAttribute("href", "/jobs/10")
    expect(screen.getByText("expected true to be false")).toBeInTheDocument()
    expect(screen.getByText("Backtrace / output")).toBeInTheDocument()
  })

  it("omits the recent executions section when history is empty", () => {
    render(<>{readTestInsightToolCard.renderExpanded(context({ parsedResult: { test, history: [] } }))}</>)

    expect(screen.queryByText(/Recent executions/)).not.toBeInTheDocument()
  })

  it("falls back to null for a malformed payload (missing test)", () => {
    const parsedResult = { oops: true }

    expect(readTestInsightToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(readTestInsightToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"

    expect(readTestInsightToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
