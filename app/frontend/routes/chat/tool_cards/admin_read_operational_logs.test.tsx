import { fireEvent, render, screen, within } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { redactToolCardValue } from "@app/toolCardSecurity"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import adminReadOperationalLogsToolCard from "./admin_read_operational_logs"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "admin_read_operational_logs",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("admin_read_operational_logs tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(adminReadOperationalLogsToolCard.toolName).toBe("admin_read_operational_logs")
  })

  it("normalizes Codex and structured MCP envelopes to the same card", () => {
    const result = { enabled: true, retention_seconds: 3600, count: 1, logs: [{ id: 1, message: "normalized" }] }
    const codexEnvelope = { content: [{ type: "text", text: JSON.stringify(result) }], structured_content: null }
    const structuredEnvelope = { content: [{ type: "text", text: "ignored" }], structured_content: result }

    expect(normalizedToolName("mcp__syrus-chat-sidecar__admin_read_operational_logs")).toBe(adminReadOperationalLogsToolCard.toolName)
    expect(adminReadOperationalLogsToolCard.collapsedSummary?.(context({ parsedResult: normalizedToolCardParsedResult(codexEnvelope) }))).toBe("1 log line")
    expect(adminReadOperationalLogsToolCard.collapsedSummary?.(context({ parsedResult: normalizedToolCardParsedResult(structuredEnvelope) }))).toBe(
      "1 log line"
    )
  })

  it("summarizes the disabled state in the collapsed row", () => {
    const parsedResult = { enabled: false, error: "operational_log_indexing_disabled", message: "disabled" }
    expect(adminReadOperationalLogsToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Operational log indexing disabled")
  })

  it("renders the disabled notice with the underlying error", () => {
    const parsedResult = { enabled: false, error: "operational_log_indexing_disabled", message: "Operational log indexing is disabled for this instance." }
    render(<>{adminReadOperationalLogsToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("Operational log indexing is disabled for this instance.")).toBeInTheDocument()
    expect(screen.getByText("operational_log_indexing_disabled")).toBeInTheDocument()
  })

  it("summarizes a healthy log search with a count", () => {
    const parsedResult = {
      enabled: true,
      retention_seconds: 3600,
      count: 2,
      logs: [
        { id: 1, level: "info", message: "a" },
        { id: 2, level: "error", message: "b" }
      ]
    }
    expect(adminReadOperationalLogsToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("2 log lines")
  })

  it("renders applied filters echoed from the tool call input", () => {
    const parsedResult = { enabled: true, retention_seconds: 3600, count: 1, logs: [{ id: 1, level: "error", message: "boom", hostname: "worker-1" }] }
    render(<>{adminReadOperationalLogsToolCard.renderExpanded(context({ parsedResult, input: { query: "boom", level: "error", limit: 25 } }))}</>)

    expect(screen.getByText("query: boom")).toBeInTheDocument()
    expect(screen.getByText("level: error")).toBeInTheDocument()
    expect(screen.getByText("limit: 25")).toBeInTheDocument()
  })

  it("renders every log field, linked attribution, and full context in the message viewer", () => {
    const secret = "secret-token-value-123456"
    const parsedResult = redactToolCardValue({
      enabled: true,
      retention_seconds: 3600,
      count: 1,
      logs: [
        {
          id: 1,
          occurred_at: "2026-09-06T00:00:00Z",
          level: "error",
          role: "worker",
          hostname: "worker-1",
          app_revision: "abc123",
          pid: 42,
          source: "rails",
          request_id: "req-1",
          message: `failed with token=${secret} ${"x".repeat(260)}`,
          context: { token: secret, visible: "detail" },
          job_id: 4048,
          workflow_id: 500,
          run_id: 600
        }
      ]
    })

    render(<>{adminReadOperationalLogsToolCard.renderExpanded(context({ parsedResult }))}</>)

    for (const value of ["abc123", "42", "rails", "req-1"]) expect(screen.getByText(value)).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-4048" })).toHaveAttribute("href", "/jobs/4048")
    expect(screen.getByRole("link", { name: "WF-500" })).toHaveAttribute("href", "/jobs/4048?tab=workflows#workflow-500")
    expect(screen.getByRole("link", { name: "RUN-600" })).toHaveAttribute("href", "/jobs/4048?tab=workflows#workflow-500")
    expect(screen.getByRole("table")).toHaveClass("sm:table")

    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    const dialog = screen.getByRole("dialog", { name: "Log message and context" })
    expect(
      within(dialog).getByText((_, element) => element?.tagName === "CODE" && element.textContent?.includes('"visible": "detail"') === true)
    ).toBeInTheDocument()
    expect(dialog).toHaveTextContent("[redacted]")
    expect(dialog).not.toHaveTextContent(secret)
  })

  it("renders tool errors as an explicit failure state", () => {
    const errorContext = context({ resultError: true, resultBody: "Error: log storage unavailable" })
    expect(adminReadOperationalLogsToolCard.collapsedSummary?.(errorContext)).toBe("Operational log search failed")
    render(<>{adminReadOperationalLogsToolCard.renderExpanded(errorContext)}</>)
    expect(screen.getByText("Operational log search failed")).toBeInTheDocument()
    expect(screen.getByText("Error: log storage unavailable")).toBeInTheDocument()
  })

  it("renders a collapsed log preview with attribution and truncates a very large payload", () => {
    const logs = Array.from({ length: 60 }, (_, index) => ({
      id: index,
      level: "info",
      occurred_at: "2026-09-06T00:00:00Z",
      message: `line ${index}`,
      job_id: 4048
    }))
    const parsedResult = { enabled: true, retention_seconds: 3600, count: logs.length, logs }

    render(<>{adminReadOperationalLogsToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("Log preview (60)")).toBeInTheDocument()
    expect(screen.getAllByText("JOB-4048").length).toBeGreaterThan(0)
    expect(screen.getByText("Showing first 50 of 60 rows.")).toBeInTheDocument()
  })

  it("renders an explicit empty state for no matching logs", () => {
    const parsedResult = { enabled: true, retention_seconds: 3600, count: 0, logs: [] }
    render(<>{adminReadOperationalLogsToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("No matching log lines.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(adminReadOperationalLogsToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(adminReadOperationalLogsToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
