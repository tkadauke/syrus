import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { redactToolCardValue } from "@app/toolCardSecurity"
import { normalizedToolCardParsedResult, normalizedToolName } from "@app/routes/chat/toolRendering"
import describeTableToolCard from "./mysql_db_browser_describe_table"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "mysql_db_browser_describe_table",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const fullPayload = {
  database: "syrus_production",
  table: "jobs",
  info: {
    available: true,
    type: "BASE TABLE",
    engine: "InnoDB",
    approximate_row_count: 15000,
    data_length_bytes: 2_097_152,
    index_length_bytes: 524_288,
    auto_increment: 15001,
    created_at: "2026-09-01T00:00:00Z",
    updated_at: "2026-10-01T00:00:00Z",
    collation: "utf8mb4_0900_ai_ci",
    comment: "Stores **workflow jobs**."
  },
  columns: {
    available: true,
    truncated: false,
    rows: [
      {
        name: "id",
        column_type: "bigint",
        data_type: "bigint",
        nullable: false,
        key: "PRI",
        default: null,
        extra: "auto_increment",
        character_max_length: null,
        numeric_precision: 20,
        numeric_scale: 0,
        comment: "Primary identifier"
      },
      {
        name: "state",
        column_type: "varchar(255)",
        data_type: "varchar",
        nullable: false,
        key: null,
        default: "queued",
        extra: null,
        character_max_length: 255,
        numeric_precision: null,
        numeric_scale: null,
        comment: "Current state"
      }
    ]
  },
  indexes: {
    available: true,
    truncated: false,
    rows: [{ name: "PRIMARY", unique: true, type: "BTREE", columns: ["id"] }]
  },
  foreign_keys: {
    available: true,
    truncated: false,
    rows: [
      {
        constraint_name: "fk_jobs_repository",
        direction: "outgoing",
        from_table: "jobs",
        from_column: "repository_id",
        to_table: "repositories",
        to_column: "id"
      }
    ]
  }
}

describe("mysql_db_browser_describe_table tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(describeTableToolCard.toolName).toBe("mysql_db_browser_describe_table")
    expect(normalizedToolName("mcp__syrus-chat-sidecar__mysql_db_browser_describe_table")).toBe(describeTableToolCard.toolName)
  })

  it("renders the same result from structured and text MCP envelopes", () => {
    const envelopes = [
      { structured_content: fullPayload, content: [{ type: "text", text: "stale" }] },
      { structured_content: null, content: [{ type: "text", text: JSON.stringify(fullPayload) }] }
    ]

    for (const envelope of envelopes) {
      expect(describeTableToolCard.collapsedSummary?.(context({ parsedResult: normalizedToolCardParsedResult(envelope) }))).toBe(
        "syrus_production.jobs (2 columns)"
      )
    }
  })

  it("summarizes the collapsed row with database.table and column count", () => {
    expect(describeTableToolCard.collapsedSummary?.(context({ parsedResult: fullPayload }))).toBe("syrus_production.jobs (2 columns)")
  })

  it("renders all input, info, column, index, and foreign-key fields", () => {
    render(
      <>
        {describeTableToolCard.renderExpanded(
          context({ input: { mysql_connection_id: 7, database: "syrus_production", table: "jobs" }, parsedResult: fullPayload })
        )}
      </>
    )

    expect(screen.getByText("InnoDB")).toBeInTheDocument()
    expect(screen.getByText("Connection #7")).toBeInTheDocument()
    expect(screen.getAllByText("syrus_production").length).toBeGreaterThan(0)
    expect(screen.getByText("2026-09-01T00:00:00Z")).toBeInTheDocument()
    expect(screen.getByText("workflow jobs")).toBeInTheDocument()
    expect(screen.getByText("varchar(255)")).toBeInTheDocument()
    expect(screen.getByText("varchar")).toBeInTheDocument()
    expect(screen.getByText("255")).toBeInTheDocument()
    expect(screen.getByText("Primary identifier")).toBeInTheDocument()
    expect(screen.getByText(/PRIMARY/)).toBeInTheDocument()
    expect(screen.getByText(/fk_jobs_repository/)).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "jobs" })).toHaveAttribute("href", "/db_browser")
    expect(screen.getByRole("link", { name: "repositories" })).toHaveAttribute("href", "/db_browser")
    expect(screen.getByText(".repository_id")).toBeInTheDocument()
    expect(screen.getByText(".id")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /copy repositories to clipboard/i })).toBeInTheDocument()
  })

  it("renders empty sections and truncation notices for every row section", () => {
    const payload = {
      ...fullPayload,
      columns: { available: true, truncated: true, rows: [] },
      indexes: { available: true, truncated: true, rows: fullPayload.indexes.rows },
      foreign_keys: { available: true, truncated: true, rows: fullPayload.foreign_keys.rows }
    }

    render(<>{describeTableToolCard.renderExpanded(context({ parsedResult: payload }))}</>)

    expect(screen.getByText("No columns.")).toBeInTheDocument()
    expect(screen.getByText(/Index list truncated/)).toBeInTheDocument()
    expect(screen.getByText(/Foreign key list truncated/)).toBeInTheDocument()
  })

  it("renders a per-section error when one section failed a GRANT check while others loaded", () => {
    const partialPayload = {
      ...fullPayload,
      indexes: { available: false, error: { class: "Mysql2::Error", message: "command denied to user", hint: "Grant broader read access." } }
    }

    render(<>{describeTableToolCard.renderExpanded(context({ parsedResult: partialPayload }))}</>)

    expect(screen.getByText("InnoDB")).toBeInTheDocument()
    expect(screen.getByText("command denied to user")).toBeInTheDocument()
    expect(screen.getByText("Grant broader read access.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }

    expect(describeTableToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(describeTableToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"

    expect(describeTableToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(describeTableToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("does not reveal secret-like column defaults after tool-card redaction", () => {
    const secret = "password=correct-horse-battery-staple"
    const payload = {
      ...fullPayload,
      columns: {
        available: true,
        truncated: false,
        rows: [{ ...fullPayload.columns.rows[1], default: secret }]
      }
    }
    const parsedResult = redactToolCardValue(payload)

    render(<>{describeTableToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.queryByText(secret)).not.toBeInTheDocument()
    expect(screen.getByText("password=[redacted]")).toBeInTheDocument()
  })
})
