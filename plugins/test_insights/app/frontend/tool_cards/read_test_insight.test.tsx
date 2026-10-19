import { fireEvent, render, screen } from "@testing-library/react"
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
  test_case: { id: 901, status: "failed", classification: "wip_repair_failure", duration_ms: 950, created_at: "2026-09-06T12:00:00Z" },
  test_run: { id: 55, grader_name: "rspec", total_count: 10, passed_count: 7, failed_count: 1, skipped_count: 1, error_count: 1, duration_ms: 12_000 },
  run: { id: 200, slug: "RUN-200", path: "/jobs/10?tab=workflows#run-200" },
  job: { id: 10, slug: "JOB-10", title: "Fix thing", path: "/jobs/10" },
  failure: {
    message: { text: `expected true to be false\n${"detail ".repeat(180)}`, truncated: true },
    backtrace: { text: "spec/foo_spec.rb:12:in `block'" },
    output: null
  }
}

describe("read_test_insight tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(readTestInsightToolCard.toolName).toBe("read_test_insight")
  })

  it("summarizes the collapsed row with the test name and status", () => {
    expect(readTestInsightToolCard.collapsedSummary?.(context({ parsedResult: { test, history: [] } }))).toBe("does something important (failed)")
  })

  it("renders repository/file links, timestamps, input state, runtime, related refs, and the recent record", () => {
    render(
      <>
        {readTestInsightToolCard.renderExpanded(
          context({
            input: { test_identity_id: 42, include_failures: false },
            parsedResult: {
              repository: { id: 1, slug: "acme/widgets", github_url: "https://github.com/acme/widgets" },
              test: {
                ...test,
                last_seen_at: "2026-09-06T12:00:00Z",
                last_failed_at: "2026-09-06T12:00:00Z",
                last_passed_at: "2026-09-05T12:00:00Z",
                last_duration_ms: 910
              },
              history_limit: 25,
              history: [],
              duration_points: [
                { test_case_id: 1, duration_ms: 700 },
                { test_case_id: 2, duration_ms: 910 }
              ],
              related: { grader_names: ["rspec"], run_refs: ["RUN-200"], job_refs: ["JOB-10"] }
            }
          })
        )}
      </>
    )

    const link = screen.getByRole("link", { name: "does something important" })
    expect(link).toHaveAttribute("href", "/repositories/1?tab=tests&test_id=42")
    expect(screen.getByText("failing")).toBeInTheDocument()
    expect(screen.getByText("flaky")).toBeInTheDocument()
    expect(screen.getByText("42")).toBeInTheDocument()
    expect(screen.getByText("abcdef1234567890")).toBeInTheDocument()
    expect(screen.getByText("40%")).toBeInTheDocument()
    expect(screen.getByText("2 failed / 3 passed of 5")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "acme/widgets" })).toHaveAttribute("href", "/repositories/1")
    expect(screen.getByRole("link", { name: "spec/foo_spec.rb" })).toHaveAttribute("href", "https://github.com/acme/widgets/blob/HEAD/spec/foo_spec.rb")
    expect(screen.getByRole("img", { name: "Runtime across 2 samples" })).toBeInTheDocument()
    expect(screen.getByText("No")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "RUN-200" })).toHaveAttribute("href", "/admin/runs/200")
    expect(screen.getByRole("link", { name: "JOB-10" })).toHaveAttribute("href", "/jobs/10")
  })

  it("renders recent executions with a run/job link and failure snippet", () => {
    render(<>{readTestInsightToolCard.renderExpanded(context({ parsedResult: { test, history_limit: 25, history: [historyEntry] } }))}</>)

    expect(screen.getByText("Recent executions (up to 25)")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "RUN-200" })).toHaveAttribute("href", "/jobs/10?tab=workflows#run-200")
    expect(screen.getByRole("link", { name: "JOB-10" })).toHaveAttribute("href", "/jobs/10")
    expect(screen.getByText("wip_repair_failure")).toBeInTheDocument()
    expect(screen.getByText("7 passed / 1 failed / 1 skipped / 1 errors of 10")).toBeInTheDocument()
    expect(screen.getByText("12.00s")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    expect(screen.getByRole("dialog", { name: "Failure message" })).toBeInTheDocument()
  })

  it("renders explicit empty states for history and runtime", () => {
    render(<>{readTestInsightToolCard.renderExpanded(context({ parsedResult: { test, history: [] } }))}</>)

    expect(screen.getByText("No recent executions.")).toBeInTheDocument()
    expect(screen.getByText("No runtime samples.")).toBeInTheDocument()
  })

  it("keeps serialization failures as degraded history rows", () => {
    render(
      <>
        {readTestInsightToolCard.renderExpanded(context({ parsedResult: { test, history: [{ test_case: { id: 902 }, error_serializing: "missing run" }] } }))}
      </>
    )
    expect(screen.getByText("Could not load this test: missing run")).toBeInTheDocument()
  })

  it("renders tool errors with the requested identity", () => {
    render(
      <>{readTestInsightToolCard.renderExpanded(context({ input: { test_identity_id: 999 }, resultError: true, parsedResult: { error: "not found" } }))}</>
    )
    expect(screen.getByText("not found")).toBeInTheDocument()
    expect(screen.getByText("999")).toBeInTheDocument()
    expect(
      readTestInsightToolCard.collapsedSummary?.(context({ input: { test_identity_id: 999 }, resultError: true, parsedResult: { error: "not found" } }))
    ).toBe("Test 999 failed to load")
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
