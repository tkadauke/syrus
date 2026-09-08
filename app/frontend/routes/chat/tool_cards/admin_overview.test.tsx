import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import adminOverviewToolCard from "./admin_overview"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "admin_overview",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const HEALTHY_PAYLOAD = {
  total_users: 8,
  active_repositories: 3,
  open_jobs: 5,
  running_workflows: 2,
  queue_summary: { active: 2, pending: 1, failed: 0 },
  overview: {
    github_rate_limits: [],
    github_api_blocked_users: [],
    provider_circuits: [],
    worker_health: { current: [{ hostname: "worker-1", health: { level: "ok", reasons: [] } }] }
  }
}

describe("admin_overview tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(adminOverviewToolCard.toolName).toBe("admin_overview")
  })

  it("summarizes the collapsed row with headline counts", () => {
    expect(adminOverviewToolCard.collapsedSummary?.(context({ parsedResult: HEALTHY_PAYLOAD }))).toBe("5 open Jobs, 2 running, 0 failed (24h)")
  })

  it("renders stat tiles and queue summary for a healthy instance", () => {
    render(<>{adminOverviewToolCard.renderExpanded(context({ parsedResult: HEALTHY_PAYLOAD }))}</>)

    expect(screen.getByText("Users")).toBeInTheDocument()
    expect(screen.getByText("8")).toBeInTheDocument()
    expect(screen.getByText("Active repos")).toBeInTheDocument()
    expect(screen.queryByText("Notable")).not.toBeInTheDocument()
  })

  it("surfaces open provider circuits, blocked users, and unhealthy workers as a degraded state", () => {
    const parsedResult = {
      ...HEALTHY_PAYLOAD,
      overview: {
        github_rate_limits: [{ email: "a@example.com", remaining: 1, limit: 100 }],
        github_api_blocked_users: [{ id: 1, email: "blocked@example.com", reason: "gh_api_blocked" }],
        provider_circuits: [{ provider: "codex", open: true, reason: "usage limit", model: "gpt-5", retry_after: "2026-09-08T00:00:00Z" }],
        worker_health: {
          current: [
            { hostname: "worker-1", health: { level: "critical", reasons: ["worker heartbeat stale"] } },
            { hostname: "worker-2", health: { level: "ok", reasons: [] } }
          ]
        }
      }
    }

    render(<>{adminOverviewToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("Notable")).toBeInTheDocument()
    expect(screen.getByText("codex")).toBeInTheDocument()
    expect(screen.getByText("usage limit")).toBeInTheDocument()
    expect(screen.getByText("blocked@example.com")).toBeInTheDocument()
    expect(screen.getByText("1 user under 10% GitHub rate limit")).toBeInTheDocument()
    expect(screen.getByText("1 of 2 workers need attention")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(adminOverviewToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(adminOverviewToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(adminOverviewToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
