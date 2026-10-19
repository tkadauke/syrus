import { fireEvent, render, screen } from "@testing-library/react"
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

  it("renders every result field, a copyable user ID, wrapped email, and the requested limit", () => {
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

    render(<>{adminListUsersToolCard.renderExpanded(context({ parsedResult, input: { limit: 40 } }))}</>)

    expect(screen.getByText("Requested limit").nextSibling).toHaveTextContent("40")
    expect(screen.getByText("1")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Copy 1 to clipboard" }))
    expect(screen.getByText("admin@example.com")).toBeInTheDocument()
    expect(screen.getByText("admin@example.com").closest("td")).toHaveClass("whitespace-normal", "break-words")
    expect(screen.getByText("admin")).toBeInTheDocument()
    expect(screen.getByText("claude")).toBeInTheDocument()
    expect(screen.getByText("paused")).toBeInTheDocument()
    expect(screen.getByText("active")).toBeInTheDocument()
    expect(screen.getByText("12")).toBeInTheDocument()
    expect(screen.getByText("2026-01-01T00:00:00Z")).toBeInTheDocument()
    const idHeading = screen.getAllByText("ID").find((label) => label.closest("th"))
    expect(idHeading?.closest("thead")).toHaveClass("hidden", "sm:table-header-group")
    expect(screen.getAllByText("Email").some((label) => label.closest("td")?.getAttribute("data-label") === "Email")).toBe(true)
  })

  it("renders an explicit empty state for a well-formed empty list", () => {
    render(<>{adminListUsersToolCard.renderExpanded(context({ parsedResult: { users: [] } }))}</>)
    expect(screen.getByText("No users found.")).toBeInTheDocument()
  })

  it("renders the default limit and an explicit error state", () => {
    const { rerender } = render(<>{adminListUsersToolCard.renderExpanded(context({ parsedResult: { users: [] } }))}</>)
    expect(screen.getByText("default (20)")).toBeInTheDocument()

    rerender(<>{adminListUsersToolCard.renderExpanded(context({ resultError: true, parsedResult: { error: "Admin access required" } }))}</>)
    expect(screen.getByText("Admin access required")).toBeInTheDocument()
  })

  it.each([
    ["structured_content", { structured_content: { users: [{ id: 7, email: "secret-token-value@example.com" }] } }],
    ["content text JSON", { content: [{ type: "text", text: JSON.stringify({ users: [{ id: 7, email: "secret-token-value@example.com" }] }) }] }]
  ])("normalizes and redacts the %s result envelope", (_label, rawResult) => {
    const parsedResult = redactToolCardValue(normalizedToolCardParsedResult(rawResult))
    render(<>{adminListUsersToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("[redacted]@example.com")).toBeInTheDocument()
  })

  it("normalizes the provider-qualified raw tool name", () => {
    expect(normalizedToolName("mcp__syrus-chat-sidecar__admin_list_users")).toBe("admin_list_users")
  })

  it("falls back to null for a malformed payload", () => {
    expect(adminListUsersToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(adminListUsersToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
