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

  it("renders linked entities, every filter, result field, and responsive labels", () => {
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
          context({ input: { state: "failed", trigger_kind: "ci_failure", job_id: 4048, since: "2026-09-01", limit: 25 }, parsedResult })
        )}
      </>
    )

    expect(screen.getByRole("link", { name: "RUN-501" })).toHaveAttribute("href", "/jobs/4048?tab=workflows#workflow-900")
    expect(screen.getByRole("link", { name: "JOB-4048" })).toHaveAttribute("href", "/jobs/4048")
    expect(screen.getByRole("link", { name: "WF-900" })).toHaveAttribute("href", "/jobs/4048?tab=workflows#workflow-900")
    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("ci_failure")).toBeInTheDocument()
    expect(screen.getByText("state: failed")).toBeInTheDocument()
    expect(screen.getByText("trigger_kind: ci_failure")).toBeInTheDocument()
    expect(screen.getByText("job_id: 4048")).toBeInTheDocument()
    expect(screen.getByText("since: 2026-09-01")).toBeInTheDocument()
    expect(screen.getByText("limit: 25")).toBeInTheDocument()
    expect(screen.getByText("2026-09-06T00:00:00Z")).toBeInTheDocument()
    expect(screen.getByText("2026-09-06T00:03:00Z")).toBeInTheDocument()
    expect(screen.getByText("$0.1234")).toBeInTheDocument()
    expect(screen.getAllByText("Run").some((element) => element.classList.contains("sm:hidden"))).toBe(true)
  })

  it("renders a tool error with redacted input and result values", () => {
    const redacted = redactToolCardValue({ input: { state: "failed", token: "secret-token-value" }, resultBody: "authorization=secret-token-value" }) as {
      input: Record<string, unknown>
      resultBody: string
    }

    render(<>{adminListRunsToolCard.renderExpanded(context({ input: redacted.input, resultBody: redacted.resultBody, resultError: true }))}</>)

    expect(adminListRunsToolCard.collapsedSummary?.(context({ resultError: true }))).toBe("Run listing failed")
    expect(screen.getByText("state: failed")).toBeInTheDocument()
    expect(screen.getByText("authorization=[redacted]")).toBeInTheDocument()
    expect(screen.queryByText(/secret-token-value/)).not.toBeInTheDocument()
  })

  it.each([
    ["structured_content", { structured_content: { runs: [{ id: 501 }] } }],
    ["content text", { content: [{ type: "text", text: JSON.stringify({ runs: [{ id: 501 }] }) }] }]
  ])("renders the shared normalized %s MCP result", (_label, envelope) => {
    expect(normalizedToolName("mcp__syrus-chat-sidecar__admin_list_runs")).toBe("admin_list_runs")
    const parsedResult = redactToolCardValue(normalizedToolCardParsedResult(envelope))
    render(<>{adminListRunsToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("RUN-501")).toBeInTheDocument()
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
