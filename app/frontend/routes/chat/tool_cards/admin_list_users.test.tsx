import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
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

  it("renders admin flag, provider, scheduling state, and job count", () => {
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

    render(<>{adminListUsersToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("admin@example.com")).toBeInTheDocument()
    expect(screen.getByText("admin")).toBeInTheDocument()
    expect(screen.getByText("claude")).toBeInTheDocument()
    expect(screen.getByText("paused")).toBeInTheDocument()
    expect(screen.getByText("active")).toBeInTheDocument()
    expect(screen.getByText("12")).toBeInTheDocument()
  })

  it("renders an explicit empty state for a well-formed empty list", () => {
    render(<>{adminListUsersToolCard.renderExpanded(context({ parsedResult: { users: [] } }))}</>)
    expect(screen.getByText("No users found.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(adminListUsersToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(adminListUsersToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
