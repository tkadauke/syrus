import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import listConnectionsToolCard from "./mysql_db_browser_list_connections"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "mysql_db_browser_list_connections",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const connection = {
  id: 1,
  label: "Primary reporting DB",
  default_database: "syrus_production",
  agentic_access_enabled: true,
  allow_writes: false,
  created_at: "2026-01-01T00:00:00Z",
  updated_at: "2026-01-01T00:00:00Z"
}

describe("mysql_db_browser_list_connections tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(listConnectionsToolCard.toolName).toBe("mysql_db_browser_list_connections")
  })

  it("summarizes the collapsed row with a connection count", () => {
    expect(listConnectionsToolCard.collapsedSummary?.(context({ parsedResult: { mysql_connections: [connection] } }))).toBe("1 connection")
  })

  it("renders label, database, agentic access, and write-access pills without exposing host/credentials", () => {
    render(<>{listConnectionsToolCard.renderExpanded(context({ parsedResult: { mysql_connections: [connection] } }))}</>)

    expect(screen.getByText("Primary reporting DB")).toBeInTheDocument()
    expect(screen.getByText("syrus_production")).toBeInTheDocument()
    expect(screen.getByText("Enabled")).toBeInTheDocument()
    expect(screen.getByText("Read-only")).toBeInTheDocument()
    expect(screen.queryByText(/password/i)).not.toBeInTheDocument()
  })

  it("renders a friendly empty state for no connections", () => {
    render(<>{listConnectionsToolCard.renderExpanded(context({ parsedResult: { mysql_connections: [] } }))}</>)

    expect(screen.getByText("No MySQL DB Browser connections configured.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }

    expect(listConnectionsToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(listConnectionsToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"

    expect(listConnectionsToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(listConnectionsToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
