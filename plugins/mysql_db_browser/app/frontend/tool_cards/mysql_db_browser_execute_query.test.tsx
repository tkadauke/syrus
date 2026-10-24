import { fireEvent, render, screen, within } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "@app/routes/chat/toolRendering"
import executeQueryToolCard from "./mysql_db_browser_execute_query"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "mysql_db_browser_execute_query",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const selectResult = {
  available: true,
  columns: ["id", "state"],
  rows: [
    [1, "queued"],
    [2, null]
  ],
  row_count: 2,
  truncated: false,
  statement: "SELECT id, state FROM jobs LIMIT 2",
  read_only: true,
  duration_ms: 12,
  generated_at: "2026-09-01T00:00:00Z"
}

const wideSelectResult = {
  available: true,
  columns: ["a", "b", "c", "d", "e", "f", "g", "h"],
  rows: [[1, 2, 3, 4, 5, 6, 7, 8]],
  row_count: 1,
  truncated: false,
  statement: "SELECT * FROM wide_table",
  read_only: true,
  duration_ms: 5,
  generated_at: "2026-09-01T00:00:00Z"
}

const writeResult = {
  available: true,
  columns: [],
  rows: [],
  row_count: 3,
  truncated: false,
  affected_rows: 3,
  statement: "UPDATE jobs SET state = 'queued' WHERE id < 4",
  read_only: false,
  duration_ms: 8,
  generated_at: "2026-09-01T00:00:00Z"
}

const errorResult = {
  available: false,
  statement: "SELECT * FROM nope",
  read_only: true,
  error: { class: "Mysql2::Error", message: "Table 'syrus_production.nope' doesn't exist" },
  duration_ms: 3,
  generated_at: "2026-09-01T00:00:00Z"
}

describe("mysql_db_browser_execute_query tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(executeQueryToolCard.toolName).toBe("mysql_db_browser_execute_query")
    expect(normalizedToolName("mcp__syrus-chat-sidecar__mysql_db_browser_execute_query")).toBe(executeQueryToolCard.toolName)
  })

  it("renders the same result from structured and text MCP envelopes", () => {
    const envelopes = [
      { structured_content: selectResult, content: [{ type: "text", text: "stale" }] },
      { structured_content: null, content: [{ type: "text", text: JSON.stringify(selectResult) }] }
    ]

    for (const envelope of envelopes) {
      const parsedResult = normalizedToolCardParsedResult(envelope)
      expect(executeQueryToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("2 rows")
    }
  })

  it("summarizes a SELECT outcome with a row count", () => {
    expect(executeQueryToolCard.collapsedSummary?.(context({ parsedResult: selectResult }))).toBe("2 rows")
  })

  it("summarizes a non-SELECT outcome with affected rows", () => {
    expect(executeQueryToolCard.collapsedSummary?.(context({ parsedResult: writeResult }))).toBe("3 rows affected")
  })

  it("summarizes a failed query with the error message", () => {
    expect(executeQueryToolCard.collapsedSummary?.(context({ parsedResult: errorResult, resultError: true }))).toBe(
      "Query failed: Table 'syrus_production.nope' doesn't exist"
    )
  })

  it("renders a tabular SELECT result including a NULL cell", () => {
    render(
      <>
        {executeQueryToolCard.renderExpanded(
          context({
            input: { mysql_connection_id: 7, mysql_connection_label: "Production replica", sql: selectResult.statement, limit: 50 },
            parsedResult: selectResult
          })
        )}
      </>
    )

    expect(screen.getByRole("columnheader", { name: "id" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "state" })).toBeInTheDocument()
    expect(screen.getByText("queued")).toBeInTheDocument()
    expect(screen.getByText("NULL")).toBeInTheDocument()
    expect(screen.getByText("Read-only")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Production replica" })).toHaveAttribute("href", "/db_browser")
    expect(screen.getByText("50")).toBeInTheDocument()
    expect(screen.getByText("2026-09-01T00:00:00Z")).toBeInTheDocument()
    expect(screen.getByText(selectResult.statement)).toBeInTheDocument()
  })

  it("renders duplicate column names with their distinct positional values", () => {
    const duplicateColumnsResult = { ...selectResult, columns: ["id", "id"], rows: [[12, 34]], row_count: 1 }

    render(<>{executeQueryToolCard.renderExpanded(context({ parsedResult: duplicateColumnsResult }))}</>)

    expect(screen.getAllByRole("columnheader", { name: "id" })).toHaveLength(2)
    expect(screen.getByText("12")).toBeInTheDocument()
    expect(screen.getByText("34")).toBeInTheDocument()
  })

  it("renders legacy object rows from persisted query results", () => {
    const legacyResult = { ...selectResult, rows: [{ id: 7, state: "succeeded" }], row_count: 1 }

    render(<>{executeQueryToolCard.renderExpanded(context({ parsedResult: legacyResult }))}</>)

    expect(screen.getByText("7")).toBeInTheDocument()
    expect(screen.getByText("succeeded")).toBeInTheDocument()
  })

  it("renders a wide result table with every column", () => {
    render(<>{executeQueryToolCard.renderExpanded(context({ parsedResult: wideSelectResult }))}</>)

    for (const column of wideSelectResult.columns) {
      expect(screen.getByRole("columnheader", { name: column })).toBeInTheDocument()
    }
  })

  it("renders a non-SELECT outcome as an affected-rows summary, not a table", () => {
    render(<>{executeQueryToolCard.renderExpanded(context({ parsedResult: writeResult }))}</>)

    expect(screen.getByText("3")).toBeInTheDocument()
    expect(screen.queryByRole("table")).not.toBeInTheDocument()
    expect(screen.getByText("UPDATE jobs SET state = 'queued' WHERE id < 4")).toBeInTheDocument()
  })

  it("renders a query error with the error message even though the call is flagged as errored", () => {
    render(<>{executeQueryToolCard.renderExpanded(context({ parsedResult: errorResult, resultError: true }))}</>)

    expect(screen.getByText("Table 'syrus_production.nope' doesn't exist")).toBeInTheDocument()
    expect(screen.getByText("SELECT * FROM nope")).toBeInTheDocument()
  })

  it("renders a friendly empty state for a SELECT with zero rows", () => {
    render(<>{executeQueryToolCard.renderExpanded(context({ parsedResult: { ...selectResult, rows: [], row_count: 0 } }))}</>)

    expect(screen.getByText("Query returned no rows.")).toBeInTheDocument()
    expect(screen.getByText("id · state")).toBeInTheDocument()
  })

  it("caps initially visible rows and reveals the complete result on demand", () => {
    const rows = Array.from({ length: 30 }, (_, index) => [index + 1, `row-${index + 1}`])
    render(<>{executeQueryToolCard.renderExpanded(context({ parsedResult: { ...selectResult, rows, row_count: rows.length } }))}</>)

    expect(screen.getByText("row-25")).toBeInTheDocument()
    expect(screen.queryByText("row-26")).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Show all 30 rows" }))
    expect(screen.getByText("row-30")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Show fewer rows" })).toBeInTheDocument()
  })

  it("redacts positional and legacy object cells by sensitive column name", () => {
    const positional = {
      ...selectResult,
      columns: ["email", "password_digest", "api_key"],
      rows: [["person@example.test", "bare-password-hash", "plain-api-token-value"]],
      row_count: 1
    }
    const { unmount } = render(<>{executeQueryToolCard.renderExpanded(context({ parsedResult: positional }))}</>)

    expect(screen.getByText("person@example.test")).toBeInTheDocument()
    expect(screen.getAllByText("[redacted]")).toHaveLength(2)
    expect(screen.queryByText("bare-password-hash")).not.toBeInTheDocument()
    expect(screen.queryByText("plain-api-token-value")).not.toBeInTheDocument()

    unmount()
    const legacy = { ...positional, rows: [{ email: "legacy@example.test", password_digest: "legacy-hash", api_key: "legacy-token" }] }
    render(<>{executeQueryToolCard.renderExpanded(context({ parsedResult: legacy }))}</>)
    expect(screen.getByText("legacy@example.test")).toBeInTheDocument()
    expect(screen.getAllByText("[redacted]")).toHaveLength(2)
  })

  it("truncates long cell values with a copy-friendly full-text modal", () => {
    const longValue = "x".repeat(400)
    render(<>{executeQueryToolCard.renderExpanded(context({ parsedResult: { ...selectResult, columns: ["notes"], rows: [[longValue]], row_count: 1 } }))}</>)

    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    expect(within(screen.getByRole("dialog")).getByText(longValue)).toBeInTheDocument()
  })

  it("uses input SQL when an error result omits its statement", () => {
    render(
      <>
        {executeQueryToolCard.renderExpanded(
          context({ input: { mysql_connection_id: 9, sql: "SELECT broken" }, parsedResult: { ...errorResult, statement: null } })
        )}
      </>
    )

    expect(screen.getByText("SELECT broken")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Connection #9" })).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }

    expect(executeQueryToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(executeQueryToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"

    expect(executeQueryToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(executeQueryToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
