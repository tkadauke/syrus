import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import listDatabasesToolCard from "./mysql_db_browser_list_databases"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "mysql_db_browser_list_databases",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const database = { name: "syrus_production", system_schema: false, default_character_set: "utf8mb4", default_collation: "utf8mb4_0900_ai_ci" }
const systemDatabase = { name: "information_schema", system_schema: true, default_character_set: "utf8mb3", default_collation: "utf8mb3_general_ci" }

describe("mysql_db_browser_list_databases tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(listDatabasesToolCard.toolName).toBe("mysql_db_browser_list_databases")
  })

  it("summarizes the collapsed row with a database count", () => {
    expect(listDatabasesToolCard.collapsedSummary?.(context({ parsedResult: { available: true, databases: [database, systemDatabase] } }))).toBe("2 databases")
  })

  it("renders database name, character set, collation, and a system badge", () => {
    render(<>{listDatabasesToolCard.renderExpanded(context({ parsedResult: { available: true, databases: [database, systemDatabase] } }))}</>)

    expect(screen.getByText(/syrus_production/)).toBeInTheDocument()
    expect(screen.getByText("utf8mb4")).toBeInTheDocument()
    expect(screen.getByText("System")).toBeInTheDocument()
  })

  it("renders a friendly empty state for no databases", () => {
    render(<>{listDatabasesToolCard.renderExpanded(context({ parsedResult: { available: true, databases: [] } }))}</>)

    expect(screen.getByText("No databases visible on this connection.")).toBeInTheDocument()
  })

  it("falls back to null when available is false", () => {
    const parsedResult = { available: false }

    expect(listDatabasesToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(listDatabasesToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"

    expect(listDatabasesToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(listDatabasesToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
