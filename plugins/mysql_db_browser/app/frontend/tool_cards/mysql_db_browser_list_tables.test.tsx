import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import listTablesToolCard from "./mysql_db_browser_list_tables"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "mysql_db_browser_list_tables",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const table = {
  name: "jobs",
  type: "BASE TABLE",
  engine: "InnoDB",
  approximate_row_count: 15000,
  data_length_bytes: 2_097_152,
  index_length_bytes: 524_288,
  comment: null
}

describe("mysql_db_browser_list_tables tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(listTablesToolCard.toolName).toBe("mysql_db_browser_list_tables")
  })

  it("summarizes the collapsed row with a table count and database", () => {
    expect(
      listTablesToolCard.collapsedSummary?.(context({ parsedResult: { available: true, database: "syrus_production", truncated: false, tables: [table] } }))
    ).toBe("1 table in syrus_production")
  })

  it("renders table name, engine, approximate row count, and data size", () => {
    render(
      <>{listTablesToolCard.renderExpanded(context({ parsedResult: { available: true, database: "syrus_production", truncated: false, tables: [table] } }))}</>
    )

    expect(screen.getByText("jobs")).toBeInTheDocument()
    expect(screen.getByText("InnoDB")).toBeInTheDocument()
    expect(screen.getByText("15,000")).toBeInTheDocument()
    expect(screen.getByText("2.0 MB")).toBeInTheDocument()
  })

  it("shows a truncation notice when the table list was truncated", () => {
    render(
      <>{listTablesToolCard.renderExpanded(context({ parsedResult: { available: true, database: "syrus_production", truncated: true, tables: [table] } }))}</>
    )

    expect(screen.getByText(/truncated/)).toBeInTheDocument()
  })

  it("renders a friendly empty state for no tables", () => {
    render(<>{listTablesToolCard.renderExpanded(context({ parsedResult: { available: true, database: "syrus_production", truncated: false, tables: [] } }))}</>)

    expect(screen.getByText("No tables in syrus_production.")).toBeInTheDocument()
  })

  it("falls back to null when available is false", () => {
    const parsedResult = { available: false, error: { class: "Mysql2::Error", message: "command denied" } }

    expect(listTablesToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(listTablesToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"

    expect(listTablesToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(listTablesToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
