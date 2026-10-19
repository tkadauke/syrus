import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { redactToolCardValue } from "@app/toolCardSecurity"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import adminListUsersToolCard from "./admin_list_users"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "admin_list_users",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("admin_list_users tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(adminListUsersToolCard.toolName).toBe("admin_list_users")
  })

  it("summarizes the collapsed row with a count", () => {
    const parsedResult = { users: [{ id: 1, email: "a@example.com" }] }
    expect(adminListUsersToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("1 user")
  })

  it("renders all result fields, a copyable ID, the requested limit, and responsive labels", () => {
    const parsedResult = {
      users: [
        {
          id: 1,
          email: "admin@example.com",
          admin: true,
          agent_provider: "claude",
          scheduling_paused: false,
          created_at: "2026-01-01T00:00:00Z",
          job_count: 12
        },
        { id: 2, email: "paused@example.com", admin: false, agent_provider: "codex", scheduling_paused: true, created_at: "2026-01-02T00:00:00Z", job_count: 0 }
      ]
    }

    render(<>{adminListUsersToolCard.renderExpanded(context({ parsedResult, input: { limit: 7 } }))}</>)

    expect(screen.getByText("Requested limit")).toBeInTheDocument()
    expect(screen.getByText("7")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Copy 1 to clipboard" })).toBeInTheDocument()
    expect(screen.getByText("admin@example.com")).toBeInTheDocument()
    expect(screen.getByText("admin")).toBeInTheDocument()
    expect(screen.getByText("claude")).toBeInTheDocument()
    expect(screen.getByText("paused")).toBeInTheDocument()
    expect(screen.getByText("active")).toBeInTheDocument()
    expect(screen.getByText("12")).toBeInTheDocument()
    expect(screen.getAllByText("ID").length).toBeGreaterThan(0)
    expect(screen.getAllByText("Email").length).toBeGreaterThan(0)
  })

  it("wraps long email addresses instead of truncating them", () => {
    const email = `${"long".repeat(20)}@example.com`
    const { container } = render(<>{adminListUsersToolCard.renderExpanded(context({ parsedResult: { users: [{ id: 1, email }] } }))}</>)

    const emailCell = screen.getByText(email).closest("td")
    expect(emailCell).toHaveClass("whitespace-normal", "break-words")
    expect(container.querySelector("table")).toHaveClass("block", "sm:table")
  })

  it.each([
    ["structured_content", { structured_content: { users: [{ id: 41, email: "structured@example.com" }] } }],
    ["content text JSON", { content: [{ type: "text", text: JSON.stringify({ users: [{ id: 42, email: "text@example.com" }] }) }] }]
  ])("normalizes sidecar-qualified %s results through the shared redaction path", (_shape, rawResult) => {
    const toolName = normalizedToolName("mcp__syrus-chat-sidecar__admin_list_users")
    const parsedResult = redactToolCardValue(normalizedToolCardParsedResult(rawResult))
    const input = redactToolCardValue({ limit: 3, api_token: "secret-value" }) as Record<string, unknown>

    expect(toolName).toBe("admin_list_users")
    render(<>{adminListUsersToolCard.renderExpanded(context({ toolName, parsedResult, input }))}</>)

    expect(screen.getByText("Requested limit")).toBeInTheDocument()
    expect(screen.getByText("3")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /Copy 4[12] to clipboard/ })).toBeInTheDocument()
    expect(JSON.stringify(input)).not.toContain("secret-value")
  })

  it("renders an explicit empty state for a well-formed empty list", () => {
    render(<>{adminListUsersToolCard.renderExpanded(context({ parsedResult: { users: [] }, input: { limit: 5 } }))}</>)
    expect(screen.getByText("Requested limit")).toBeInTheDocument()
    expect(screen.getByText("No users found.")).toBeInTheDocument()
  })

  it("defers tool errors to the shared error card", () => {
    expect(adminListUsersToolCard.renderExpanded(context({ resultError: true, parsedResult: { error: "Admin access required" } }))).toBeNull()
  })

  it("falls back to null for a malformed payload", () => {
    expect(adminListUsersToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(adminListUsersToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
