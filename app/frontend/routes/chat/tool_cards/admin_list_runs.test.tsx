import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import adminListRunsToolCard from "./admin_list_runs"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "admin_list_runs",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("admin_list_runs tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(adminListRunsToolCard.toolName).toBe("admin_list_runs")
  })

  it("summarizes the collapsed row with a count", () => {
    const parsedResult = { runs: [{ id: 1 }, { id: 2 }] }
    expect(adminListRunsToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("2 Runs")
  })

  it("renders a Run row with a Job link, state, trigger, timing, and cost", () => {
    const parsedResult = {
      runs: [{
        id: 501,
        job_id: 148,
        workflow_id: 900,
        state: "failed",
        trigger_kind: "ci_failure",
        started_at: "2026-09-06T00:00:00Z",
        finished_at: "2026-09-06T00:03:00Z",
        cost_usd: "0.1234"
      }]
    }

    render(<>{adminListRunsToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("RUN-501")).toBeInTheDocument()
    const link = screen.getByRole("link", { name: "JOB-148" })
    expect(link).toHaveAttribute("href", "/jobs/148")
    expect(screen.getByText("WF-900")).toBeInTheDocument()
    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("ci_failure")).toBeInTheDocument()
  })

  it("renders an explicit empty state for a well-formed empty list", () => {
    render(<>{adminListRunsToolCard.renderExpanded(context({ parsedResult: { runs: [] } }))}</>)
    expect(screen.getByText("No Runs found.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(adminListRunsToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(adminListRunsToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
