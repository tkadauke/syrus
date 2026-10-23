import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "@app/routes/chat/toolRendering"
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

  it("renders every safe metadata field with copyable ids, links, and responsive layout", () => {
    render(<>{listConnectionsToolCard.renderExpanded(context({ parsedResult: { mysql_connections: [connection] } }))}</>)

    expect(screen.getByRole("link", { name: "Primary reporting DB" })).toHaveAttribute("href", "/db_browser?connection_id=1")
    expect(screen.getByRole("link", { name: "Manage DB Browser connections" })).toHaveAttribute("href", "/db_browser")
    expect(screen.getByRole("button", { name: "Copy 1 to clipboard" })).toBeInTheDocument()
    expect(screen.getByText("syrus_production")).toBeInTheDocument()
    expect(screen.getByText("Enabled")).toBeInTheDocument()
    expect(screen.getByText("Read-only")).toBeInTheDocument()
    expect(screen.getAllByText("2026-01-01T00:00:00Z")).toHaveLength(2)
    expect(screen.getByText("Created at")).toBeInTheDocument()
    expect(screen.getByText("Updated at")).toBeInTheDocument()
    expect(screen.getByText("Connection ID").closest(".grid")).toHaveClass("sm:grid-cols-2")
  })

  it("explains how to enable agentic access in the empty state", () => {
    render(<>{listConnectionsToolCard.renderExpanded(context({ parsedResult: { mysql_connections: [] } }))}</>)

    expect(screen.getByText(/Enable agentic access/)).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Manage DB Browser connections" })).toHaveAttribute("href", "/db_browser")
  })

  it("shows a clear warning for write-enabled connections", () => {
    render(<>{listConnectionsToolCard.renderExpanded(context({ parsedResult: { mysql_connections: [{ ...connection, allow_writes: true }] } }))}</>)

    expect(screen.getByText("Writes enabled")).toBeInTheDocument()
    expect(screen.getByText("Read-write")).toBeInTheDocument()
  })

  it("renders structured errors", () => {
    render(
      <>
        {listConnectionsToolCard.renderExpanded(
          context({ parsedResult: { error: { class: "AccessDenied", message: "Not authorized", hint: "Ask an admin." } } })
        )}
      </>
    )

    expect(screen.getByText("Not authorized")).toBeInTheDocument()
    expect(screen.getByText("Ask an admin.")).toBeInTheDocument()
  })

  it.each([
    ["Claude", "mcp__syrus-chat-sidecar__mysql_db_browser_list_connections", { mysql_connections: [connection] }],
    ["Codex", "mysql_db_browser_list_connections", { structured_content: { mysql_connections: [connection] } }],
    ["Muse", "syrus-chat-sidecar.mysql_db_browser_list_connections", { content: [{ type: "text", text: JSON.stringify({ mysql_connections: [connection] }) }] }]
  ])("renders the same card for %s result envelopes", (_provider, rawName, envelope) => {
    expect(normalizedToolName(rawName)).toBe("mysql_db_browser_list_connections")
    const parsedResult = normalizedToolCardParsedResult(envelope)
    expect(listConnectionsToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("1 connection")
    render(<>{listConnectionsToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByRole("link", { name: "Primary reporting DB" })).toBeInTheDocument()
    expect(screen.getAllByText("2026-01-01T00:00:00Z")).toHaveLength(2)
  })

  it("renders only allowlisted metadata and never host or credentials", () => {
    const unsafe = { ...connection, host: "prod-db.internal", username: "reporter", password: "correct-horse-battery-staple" }
    render(<>{listConnectionsToolCard.renderExpanded(context({ parsedResult: { mysql_connections: [unsafe] } }))}</>)

    expect(screen.queryByText("prod-db.internal")).not.toBeInTheDocument()
    expect(screen.queryByText("reporter")).not.toBeInTheDocument()
    expect(screen.queryByText("correct-horse-battery-staple")).not.toBeInTheDocument()
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
