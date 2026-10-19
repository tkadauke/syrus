import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { redactToolCardValue } from "@app/toolCardSecurity"
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

  it("renders every result field with linked entity references and a responsive layout", () => {
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

    render(<>{adminListRunsToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("RUN-501")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "RUN-501" })).toHaveAttribute("href", "/jobs/4048?tab=workflows#workflow-900")
    expect(screen.getByRole("link", { name: "JOB-4048" })).toHaveAttribute("href", "/jobs/4048")
    expect(screen.getByRole("link", { name: "WF-900" })).toHaveAttribute("href", "/jobs/4048?tab=workflows#workflow-900")
    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("ci_failure")).toBeInTheDocument()
    expect(screen.getByText("2026-09-06T00:00:00Z")).toBeInTheDocument()
    expect(screen.getByText("2026-09-06T00:03:00Z")).toBeInTheDocument()
    expect(screen.getByText("$0.1234")).toBeInTheDocument()
    expect(screen.getByRole("table")).toHaveClass("block", "sm:table")
    expect(screen.getByRole("link", { name: "RUN-501" }).closest("td")).toHaveAttribute("data-label", "Run")
  })

  it("echoes every supplied filter", () => {
    const input = { state: "failed", trigger_kind: "ci_failure", job_id: 4048, since: "2026-09-01T00:00:00Z", limit: 25 }
    render(<>{adminListRunsToolCard.renderExpanded(context({ input, parsedResult: { runs: [] } }))}</>)

    for (const label of ["state: failed", "trigger_kind: ci_failure", "job_id: 4048", "since: 2026-09-01T00:00:00Z", "limit: 25"]) {
      expect(screen.getByText(label)).toBeInTheDocument()
    }
  })

  it("renders an explicit empty state for a well-formed empty list", () => {
    render(<>{adminListRunsToolCard.renderExpanded(context({ parsedResult: { runs: [] } }))}</>)
    expect(screen.getByText("No Runs found.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(adminListRunsToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(adminListRunsToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })

  it("renders an explicit tool error state", () => {
    const failed = context({ resultError: true, resultBody: "Admin access required", parsedResult: null })
    expect(adminListRunsToolCard.collapsedSummary?.(failed)).toBe("Run search failed")
    render(<>{adminListRunsToolCard.renderExpanded(failed)}</>)
    expect(screen.getByText("Admin access required")).toBeInTheDocument()
  })

  it.each([
    ["structured_content", { structured_content: { runs: [{ id: 501 }] } }],
    ["content text JSON", { content: [{ type: "text", text: JSON.stringify({ runs: [{ id: 501 }] }) }] }]
  ])("normalizes %s results through the shared redaction boundary", (_label, payload) => {
    const parsedResult = redactToolCardValue(normalizedToolCardParsedResult(payload))
    const toolName = normalizedToolName("mcp__syrus-chat-sidecar__admin_list_runs")
    expect(adminListRunsToolCard.collapsedSummary?.(context({ toolName, parsedResult }))).toBe("1 Run")
  })
})
