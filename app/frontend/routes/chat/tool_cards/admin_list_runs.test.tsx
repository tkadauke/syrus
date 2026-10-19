import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { redactToolCardValue } from "../../../toolCardSecurity"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
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

  it("renders linked entities, every result field, echoed filters, and responsive labels", () => {
    const parsedResult = {
      runs: [
        {
          id: 501,
          job_id: 4048,
          workflow_id: 900,
          state: "failed",
          trigger_kind: "ci_failure",
          started_at: "2026-09-06T00:00:00Z",
          finished_at: "2026-09-06T00:03:00Z",
          cost_usd: "0.1234"
        }
      ]
    }

    render(
      <>
        {adminListRunsToolCard.renderExpanded(
          context({
            input: { state: "failed", trigger_kind: "ci_failure", job_id: 4048, since: "2026-09-01", limit: 25 },
            parsedResult
          })
        )}
      </>
    )

    expect(screen.getByRole("link", { name: "RUN-501" })).toHaveAttribute("href", "/jobs/4048?tab=workflows#workflow-900")
    expect(screen.getByRole("link", { name: "JOB-4048" })).toHaveAttribute("href", "/jobs/4048")
    expect(screen.getByRole("link", { name: "WF-900" })).toHaveAttribute("href", "/jobs/4048?tab=workflows#workflow-900")
    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("ci_failure")).toBeInTheDocument()
    expect(screen.getByText("2026-09-06T00:00:00Z")).toBeInTheDocument()
    expect(screen.getByText("2026-09-06T00:03:00Z")).toBeInTheDocument()
    expect(screen.getByText("$0.1234")).toBeInTheDocument()
    for (const filter of ["state: failed", "trigger_kind: ci_failure", "job_id: 4048", "since: 2026-09-01", "limit: 25"]) {
      expect(screen.getByText(filter)).toBeInTheDocument()
    }
    expect(screen.getByText("Run", { selector: "td span" })).toBeInTheDocument()
  })

  it("renders an explicit empty state for a well-formed empty list", () => {
    render(<>{adminListRunsToolCard.renderExpanded(context({ parsedResult: { runs: [] } }))}</>)
    expect(screen.getByText("No Runs found.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(adminListRunsToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(adminListRunsToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })

  it("renders an explicit tool error with redacted filters", () => {
    const input = redactToolCardValue({ state: "failed", token: "secret-value-123456" }) as Record<string, unknown>
    render(<>{adminListRunsToolCard.renderExpanded(context({ input, resultError: true, resultBody: "Worker unavailable" }))}</>)

    expect(screen.getByText("state: failed")).toBeInTheDocument()
    expect(screen.getByText("Worker unavailable")).toBeInTheDocument()
    expect(screen.queryByText(/secret-value/)).not.toBeInTheDocument()
    expect(adminListRunsToolCard.collapsedSummary?.(context({ resultError: true }))).toBe("Failed to list Runs")
  })

  it.each([
    ["direct", { runs: [{ id: 701 }] }],
    ["structured_content", { structured_content: { runs: [{ id: 701 }] }, content: [] }],
    ["content text", { structured_content: null, content: [{ type: "text", text: JSON.stringify({ runs: [{ id: 701 }] }) }] }]
  ])("normalizes %s results from the namespaced MCP tool", (_source, payload) => {
    const parsedResult = redactToolCardValue(normalizedToolCardParsedResult(payload))

    expect(normalizedToolName("mcp__syrus-chat-sidecar__admin_list_runs")).toBe("admin_list_runs")
    expect(adminListRunsToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("1 Run")
  })
})
