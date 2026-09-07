import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
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
  columns: [ "id", "state" ],
  rows: [ { id: 1, state: "queued" }, { id: 2, state: null } ],
  row_count: 2,
  truncated: false,
  statement: "SELECT id, state FROM jobs LIMIT 2",
  read_only: true,
  duration_ms: 12,
  generated_at: "2026-09-01T00:00:00Z"
}

const wideSelectResult = {
  available: true,
  columns: [ "a", "b", "c", "d", "e", "f", "g", "h" ],
  rows: [ { a: 1, b: 2, c: 3, d: 4, e: 5, f: 6, g: 7, h: 8 } ],
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
  })

  it("summarizes a SELECT outcome with a row count", () => {
    expect(executeQueryToolCard.collapsedSummary?.(context({ parsedResult: selectResult }))).toBe("2 rows")
  })

  it("summarizes a non-SELECT outcome with affected rows", () => {
    expect(executeQueryToolCard.collapsedSummary?.(context({ parsedResult: writeResult }))).toBe("3 rows affected")
  })

  it("summarizes a failed query with the error message", () => {
    expect(executeQueryToolCard.collapsedSummary?.(context({ parsedResult: errorResult, resultError: true }))).toBe("Query failed: Table 'syrus_production.nope' doesn't exist")
  })

  it("renders a tabular SELECT result including a NULL cell", () => {
    render(<>{executeQueryToolCard.renderExpanded(context({ parsedResult: selectResult }))}</>)

    expect(screen.getByRole("columnheader", { name: "id" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "state" })).toBeInTheDocument()
    expect(screen.getByText("queued")).toBeInTheDocument()
    expect(screen.getByText("NULL")).toBeInTheDocument()
    expect(screen.getByText("read-only")).toBeInTheDocument()
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

  it("renders a query error with the error message", () => {
    render(<>{executeQueryToolCard.renderExpanded(context({ parsedResult: errorResult, resultError: true }))}</>)

    expect(screen.getByText("Table 'syrus_production.nope' doesn't exist")).toBeInTheDocument()
    expect(screen.getByText("SELECT * FROM nope")).toBeInTheDocument()
  })

  it("renders a friendly empty state for a SELECT with zero rows", () => {
    render(<>{executeQueryToolCard.renderExpanded(context({ parsedResult: { ...selectResult, rows: [], row_count: 0 } }))}</>)

    expect(screen.getByText("Query returned no rows.")).toBeInTheDocument()
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
