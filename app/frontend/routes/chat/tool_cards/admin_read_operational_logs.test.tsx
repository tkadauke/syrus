import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
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
    const parsedResult = { enabled: true, retention_seconds: 3600, count: 2, logs: [{ id: 1, level: "info", message: "a" }, { id: 2, level: "error", message: "b" }] }
    expect(adminReadOperationalLogsToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("2 log lines")
  })

  it("renders applied filters echoed from the tool call input", () => {
    const parsedResult = { enabled: true, retention_seconds: 3600, count: 1, logs: [{ id: 1, level: "error", message: "boom", hostname: "worker-1" }] }
    render(<>{adminReadOperationalLogsToolCard.renderExpanded(context({ parsedResult, input: { query: "boom", level: "error" } }))}</>)

    expect(screen.getByText("query: boom")).toBeInTheDocument()
    expect(screen.getByText("level: error")).toBeInTheDocument()
  })

  it("renders a collapsed log preview with attribution and truncates a very large payload", () => {
    const logs = Array.from({ length: 60 }, (_, index) => ({ id: index, level: "info", occurred_at: "2026-09-06T00:00:00Z", message: `line ${index}`, job_id: 4048 }))
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
