import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "@app/routes/chat/toolRendering"
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
  fingerprint: "abc123def456",
  last_seen_at: "2026-10-18T10:00:00Z",
  last_failed_at: "2026-10-17T09:00:00Z",
  total_count: 10,
  failed_count: 5,
  passed_count: 5,
  runtime_summary: { sample_count: 10, p50_duration_ms: 1100, p95_duration_ms: 1900 },
  links: { app_path: "/repositories/1?tab=tests&test_id=42" },
  latest: {
    run: { slug: "RUN-9", path: "/jobs/3?tab=workflows#run-9" },
    workflow: { slug: "WF-8", path: "/jobs/3?tab=workflows#workflow-8" },
    job: { slug: "JOB-3", path: "/jobs/3" }
  }
}

const repository = { id: 1, slug: "acme/widgets", github_url: "https://github.com/acme/widgets" }

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

  it("renders a wrapping repository row with every metric and link", () => {
    render(
      <>
        {listRepositoryTestInsightsToolCard.renderExpanded(
          context({
            input: { filters: { min_failure_rate: 0.25 } },
            parsedResult: {
              repository,
              filter: "failing",
              sort: "last_failed",
              direction: "desc",
              query: "widget",
              grader_name: "rspec",
              lookback: 50,
              summary_window: 100,
              limit: 25,
              tests: [failingTest]
            }
          })
        )}
      </>
    )

    expect(screen.getByRole("link", { name: "acme/widgets" })).toHaveAttribute("href", "/repositories/1")
    const link = screen.getByRole("link", { name: "does something important" })
    expect(link).toHaveAttribute("href", "/repositories/1?tab=tests&test_id=42")
    expect(screen.getByRole("link", { name: "spec/foo_spec.rb" })).toHaveAttribute("href", "https://github.com/acme/widgets/blob/HEAD/spec/foo_spec.rb")
    expect(screen.getAllByText("failing")).toHaveLength(2)
    expect(screen.getByText("slow")).toBeInTheDocument()
    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("50%")).toBeInTheDocument()
    expect(screen.getByText("1.50s")).toBeInTheDocument()
    expect(screen.getByText("1.20s")).toBeInTheDocument()
    expect(screen.getByText("5 failed / 5 passed of 10")).toBeInTheDocument()
    expect(screen.getByText("1.10s / 1.90s (10)")).toBeInTheDocument()
    expect(screen.getByText("abc123def456")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "RUN-9" })).toHaveAttribute("href", "/jobs/3?tab=workflows#run-9")
    expect(screen.getByRole("link", { name: "WF-8" })).toHaveAttribute("href", "/jobs/3?tab=workflows#workflow-8")
    expect(screen.getByRole("link", { name: "JOB-3" })).toHaveAttribute("href", "/jobs/3")
    expect(screen.getByText("min failure rate")).toBeInTheDocument()
    expect(screen.getByText("0.25")).toBeInTheDocument()
    for (const value of ["last_failed", "desc", "widget", "rspec", "50", "100", "25"]) expect(screen.getByText(value)).toBeInTheDocument()
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

  it("keeps degraded and pending rows visible", () => {
    render(
      <>
        {listRepositoryTestInsightsToolCard.renderExpanded(
          context({
            parsedResult: {
              tests: [
                { id: 50, name: "still queued", last_status: "pending" },
                { id: 51, error_serializing: "broken association" }
              ]
            }
          })
        )}
      </>
    )
    expect(screen.getByText("still queued")).toBeInTheDocument()
    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText(/broken association/)).toBeInTheDocument()
    expect(screen.getByText("Unavailable test")).toBeInTheDocument()
  })

  it("uses the common provider name and envelope normalizers", () => {
    const payload = { repository, tests: [failingTest] }
    const envelope = { content: [{ type: "text", text: JSON.stringify(payload) }], structured_content: null }
    expect(normalizedToolName("mcp__syrus__list_repository_test_insights")).toBe(listRepositoryTestInsightsToolCard.toolName)
    expect(listRepositoryTestInsightsToolCard.collapsedSummary?.(context({ parsedResult: normalizedToolCardParsedResult(envelope) }))).toBe(
      "1 test in acme/widgets"
    )
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
