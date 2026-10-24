import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { toolCardContextForExample, type ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "@app/routes/chat/toolRendering"
import listDatabasesToolCard, { examples } from "./mysql_db_browser_list_databases"

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
const result = { available: true, generated_at: "2026-10-23T10:00:00Z", databases: [database, systemDatabase] }

describe("mysql_db_browser_list_databases tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(listDatabasesToolCard.toolName).toBe("mysql_db_browser_list_databases")
  })

  it("registers populated, empty, and error states for catalog review", () => {
    expect(examples.map((example) => example.id)).toEqual(["databases_with_system_schemas", "no_visible_databases", "database_list_error"])
  })

  it("resolves the connection label from the populated catalog example's prior calls", () => {
    const exampleContext = toolCardContextForExample(listDatabasesToolCard.toolName, examples[0]!)

    render(<>{listDatabasesToolCard.renderExpanded(exampleContext)}</>)

    expect(screen.getByRole("link", { name: "Production reporting (#7)" })).toHaveAttribute("href", "/db_browser?connection_id=7")
  })

  it("summarizes the collapsed row with a database count", () => {
    expect(listDatabasesToolCard.collapsedSummary?.(context({ parsedResult: { available: true, databases: [database, systemDatabase] } }))).toBe("2 databases")
  })

  it("renders connection context, every result field, filtering, and collapsed system schemas", () => {
    render(
      <>
        {listDatabasesToolCard.renderExpanded(
          context({
            input: { mysql_connection_id: 7 },
            priorResults: { mysql_db_browser_list_connections: { mysql_connections: [{ id: 7, label: "Production reporting" }] } },
            parsedResult: result
          })
        )}
      </>
    )

    expect(screen.getByRole("link", { name: "Production reporting (#7)" })).toHaveAttribute("href", "/db_browser?connection_id=7")
    expect(screen.getByText("2026-10-23T10:00:00Z")).toBeInTheDocument()
    expect(screen.getByText("syrus_production")).toBeInTheDocument()
    expect(screen.getByText("utf8mb4")).toBeInTheDocument()
    expect(screen.getByText("information_schema").closest("details")).not.toHaveAttribute("open")
    fireEvent.click(screen.getByText("1 system schema"))
    expect(screen.getByText("information_schema").closest("details")).toHaveAttribute("open")

    fireEvent.change(screen.getByRole("searchbox", { name: "Filter databases" }), { target: { value: "missing" } })
    expect(screen.getByText("No matching databases.")).toBeInTheDocument()
  })

  it("renders a friendly empty state for no databases", () => {
    render(<>{listDatabasesToolCard.renderExpanded(context({ parsedResult: { available: true, databases: [] } }))}</>)

    expect(screen.getByText("No databases visible on this connection.")).toBeInTheDocument()
  })

  it("renders input context and structured errors", () => {
    const parsedResult = { available: false, error: { class: "AccessDenied", message: "Not authorized", hint: "Ask an admin." } }
    render(<>{listDatabasesToolCard.renderExpanded(context({ input: { mysql_connection_id: 7 }, parsedResult }))}</>)

    expect(screen.getByRole("link", { name: "Connection #7" })).toHaveAttribute("href", "/db_browser?connection_id=7")
    expect(screen.getByText("Not authorized")).toBeInTheDocument()
    expect(screen.getByText("Ask an admin.")).toBeInTheDocument()
    expect(listDatabasesToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
  })

  it.each([
    ["Claude", "mcp__syrus-chat-sidecar__mysql_db_browser_list_databases", result],
    ["Codex", "mysql_db_browser_list_databases", { structured_content: result }],
    ["Muse", "syrus-chat-sidecar.mysql_db_browser_list_databases", { content: [{ type: "text", text: JSON.stringify(result) }] }]
  ])("renders the same card for %s result envelopes", (_provider, rawName, envelope) => {
    expect(normalizedToolName(rawName)).toBe("mysql_db_browser_list_databases")
    const parsedResult = normalizedToolCardParsedResult(envelope)
    expect(listDatabasesToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("2 databases")
    render(<>{listDatabasesToolCard.renderExpanded(context({ input: { mysql_connection_id: 7 }, parsedResult }))}</>)
    expect(screen.getByRole("link", { name: "Connection #7" })).toBeInTheDocument()
    expect(screen.getByText("2026-10-23T10:00:00Z")).toBeInTheDocument()
  })

  it("renders only allowlisted metadata and never credentials", () => {
    const unsafe = { ...result, host: "prod-db.internal", username: "reporter", password: "correct-horse-battery-staple" }
    render(<>{listDatabasesToolCard.renderExpanded(context({ input: { mysql_connection_id: 7, password: "input-secret" }, parsedResult: unsafe }))}</>)

    expect(screen.queryByText("prod-db.internal")).not.toBeInTheDocument()
    expect(screen.queryByText("reporter")).not.toBeInTheDocument()
    expect(screen.queryByText("correct-horse-battery-staple")).not.toBeInTheDocument()
    expect(screen.queryByText("input-secret")).not.toBeInTheDocument()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"

    expect(listDatabasesToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(listDatabasesToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
