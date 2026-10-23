import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { redactToolCardValue } from "@app/toolCardSecurity"
import { normalizedToolCardParsedResult, normalizedToolName } from "@app/routes/chat/toolRendering"
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
  created_at: "2026-09-01T00:00:00Z",
  updated_at: "2026-10-01T00:00:00Z",
  comment: "Stores **workflow jobs**."
}

const payload = {
  available: true,
  generated_at: "2026-10-23T10:00:00Z",
  database: "syrus_production",
  system_schema: false,
  truncated: false,
  tables: [table]
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

  it("renders inputs and every table and result metadata field", () => {
    render(<>{listTablesToolCard.renderExpanded(context({ input: { mysql_connection_id: 7, database: "requested_database" }, parsedResult: payload }))}</>)

    expect(screen.getByText("jobs")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "jobs" })).toHaveAttribute(
      "href",
      "/db_browser?connection_id=7&database=requested_database&table=jobs&tab=structure"
    )
    expect(screen.getByRole("button", { name: "Copy jobs to clipboard" })).toBeInTheDocument()
    expect(screen.getByText("Connection #7")).toBeInTheDocument()
    expect(screen.getByText("requested_database")).toBeInTheDocument()
    expect(screen.getByText("syrus_production")).toBeInTheDocument()
    expect(screen.getByText("No")).toBeInTheDocument()
    expect(screen.getByText("2026-10-23T10:00:00Z")).toBeInTheDocument()
    expect(screen.getByText("BASE TABLE · InnoDB")).toBeInTheDocument()
    expect(screen.getByText("15,000")).toBeInTheDocument()
    expect(screen.getByText("2.0 MB")).toBeInTheDocument()
    expect(screen.getByText("512.0 KB")).toBeInTheDocument()
    expect(screen.getByText("2026-09-01T00:00:00Z")).toBeInTheDocument()
    expect(screen.getByText("2026-10-01T00:00:00Z")).toBeInTheDocument()
    expect(screen.getByText("workflow jobs")).toBeInTheDocument()
  })

  it("filters large table lists by name and metadata", () => {
    const auditTable = { ...table, name: "audit_events", engine: "MyISAM", comment: null }
    render(<>{listTablesToolCard.renderExpanded(context({ parsedResult: { ...payload, tables: [table, auditTable] } }))}</>)

    fireEvent.change(screen.getByRole("searchbox", { name: "Filter tables" }), { target: { value: "audit" } })
    expect(screen.getByText("audit_events")).toBeInTheDocument()
    expect(screen.queryByText("jobs")).not.toBeInTheDocument()
    expect(screen.getByText("1 of 2")).toBeInTheDocument()
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

  it("renders errors with the echoed inputs", () => {
    const parsedResult = { available: false, error: { class: "Mysql2::Error", message: "command denied" } }

    expect(listTablesToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    render(<>{listTablesToolCard.renderExpanded(context({ input: { mysql_connection_id: 7, database: "private_db" }, parsedResult }))}</>)
    expect(screen.getByText("command denied")).toBeInTheDocument()
    expect(screen.getByText("Connection #7")).toBeInTheDocument()
    expect(screen.getByText("private_db")).toBeInTheDocument()
  })

  it.each([
    ["Claude", "mcp__syrus-chat-sidecar__mysql_db_browser_list_tables", payload],
    ["Codex", "mysql_db_browser_list_tables", { structured_content: payload }],
    ["Muse", "syrus-chat-sidecar.mysql_db_browser_list_tables", { content: [{ type: "text", text: JSON.stringify(payload) }] }]
  ])("renders the same card for %s result envelopes", (_provider, rawName, envelope) => {
    expect(normalizedToolName(rawName)).toBe("mysql_db_browser_list_tables")
    const parsedResult = normalizedToolCardParsedResult(envelope)
    expect(listTablesToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("1 table in syrus_production")
    render(<>{listTablesToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("jobs")).toBeInTheDocument()
    expect(screen.getByText("2026-10-23T10:00:00Z")).toBeInTheDocument()
  })

  it("does not reveal secrets after tool-card redaction", () => {
    const secret = "password=correct-horse-battery-staple"
    const parsedResult = redactToolCardValue({ ...payload, tables: [{ ...table, comment: secret }] })
    render(<>{listTablesToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.queryByText(secret)).not.toBeInTheDocument()
    expect(screen.getByText("password=[redacted]")).toBeInTheDocument()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"

    expect(listTablesToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(listTablesToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
