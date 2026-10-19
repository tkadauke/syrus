import { fireEvent, render, screen } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"
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
  beforeEach(() => {
    Object.assign(navigator, { clipboard: { writeText: vi.fn().mockResolvedValue(undefined) } })
  })

  it("registers under the exact MCP tool name", () => {
    expect(adminListUsersToolCard.toolName).toBe("admin_list_users")
  })

  it("summarizes the collapsed row with a count", () => {
    const parsedResult = { users: [{ id: 1, email: "a@example.com" }] }
    expect(adminListUsersToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("1 user")
  })

  it("renders the requested limit and every returned user field", () => {
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

    render(<>{adminListUsersToolCard.renderExpanded(context({ input: { limit: 50 }, parsedResult }))}</>)

    expect(screen.getByText("Requested limit")).toBeInTheDocument()
    expect(screen.getByText("50")).toBeInTheDocument()
    expect(screen.getByText("1")).toBeInTheDocument()
    expect(screen.getByText("admin@example.com")).toBeInTheDocument()
    expect(screen.getByText("admin")).toBeInTheDocument()
    expect(screen.getByText("claude")).toBeInTheDocument()
    expect(screen.getByText("paused")).toBeInTheDocument()
    expect(screen.getByText("active")).toBeInTheDocument()
    expect(screen.getByText("12")).toBeInTheDocument()
    expect(screen.getByText("2026-01-01T00:00:00Z")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Copy 1 to clipboard" }))
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith("1")

    const emailCell = screen.getByText("admin@example.com").closest("td")
    expect(emailCell).toHaveClass("whitespace-normal", "break-words")
    expect(emailCell).toHaveAttribute("data-label", "Email")
    expect(screen.getAllByText("ID").some((label) => label.classList.contains("sm:hidden"))).toBe(true)
  })

  it("shows the backend default when limit is omitted", () => {
    render(<>{adminListUsersToolCard.renderExpanded(context({ parsedResult: { users: [{ id: 1 }] } }))}</>)
    expect(screen.getByText("20 (default)")).toBeInTheDocument()
  })

  it.each([
    ["structured content", { structured_content: { users: [{ id: 3, email: "structured@example.com" }] } }],
    ["text content", { content: [{ type: "text", text: JSON.stringify({ users: [{ id: 3, email: "structured@example.com" }] }) }] }]
  ])("uses the shared normalizers and redaction path for %s", (_label, rawResult) => {
    const parsedResult = redactToolCardValue(normalizedToolCardParsedResult(rawResult))
    const toolName = normalizedToolName("mcp__syrus-chat-sidecar__admin_list_users")

    expect(toolName).toBe("admin_list_users")
    render(<>{adminListUsersToolCard.renderExpanded(context({ toolName, parsedResult }))}</>)
    expect(screen.getByText("structured@example.com")).toBeInTheDocument()
  })

  it("renders an explicit empty state for a well-formed empty list", () => {
    render(<>{adminListUsersToolCard.renderExpanded(context({ parsedResult: { users: [] } }))}</>)
    expect(screen.getByText("No users found.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(adminListUsersToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(adminListUsersToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })

  it("falls through to the shared error card for failed results", () => {
    expect(adminListUsersToolCard.renderExpanded(context({ resultError: true, resultBody: "Admin access required" }))).toBeNull()
  })
})
