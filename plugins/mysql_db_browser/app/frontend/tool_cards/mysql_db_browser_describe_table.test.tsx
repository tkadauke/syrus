import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
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
    collation: "utf8mb4_0900_ai_ci",
    comment: null
  },
  columns: {
    available: true,
    truncated: false,
    rows: [
      { name: "id", column_type: "bigint", data_type: "bigint", nullable: false, key: "PRI", default: null, extra: "auto_increment" },
      { name: "state", column_type: "varchar(255)", data_type: "varchar", nullable: false, key: null, default: "queued", extra: null }
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
  })

  it("summarizes the collapsed row with database.table and column count", () => {
    expect(describeTableToolCard.collapsedSummary?.(context({ parsedResult: fullPayload }))).toBe("syrus_production.jobs (2 columns)")
  })

  it("renders info, columns, indexes, and foreign keys", () => {
    render(<>{describeTableToolCard.renderExpanded(context({ parsedResult: fullPayload }))}</>)

    expect(screen.getByText("InnoDB")).toBeInTheDocument()
    expect(screen.getByText("id")).toBeInTheDocument()
    expect(screen.getByText("varchar(255)")).toBeInTheDocument()
    expect(screen.getByText(/PRIMARY/)).toBeInTheDocument()
    expect(screen.getByText(/fk_jobs_repository|jobs\.repository_id/)).toBeInTheDocument()
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
})
