import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import adminVersionToolCard from "./admin_version"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "admin_version",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const HEALTHY_PAYLOAD = {
  request_handler: { hostname: "web-1", role: "web", version: "abc123" },
  instances: [
    {
      id: 1,
      hostname: "web-1",
      role: "web",
      version: "abc123",
      started_at: "2026-09-01T00:00:00Z",
      last_heartbeat_at: "2026-09-06T00:00:00Z",
      data_root_usage: null
    },
    {
      id: 2,
      hostname: "worker-1",
      role: "worker",
      version: "abc123",
      started_at: "2026-09-01T00:00:00Z",
      last_heartbeat_at: "2026-09-06T00:00:00Z",
      data_root_usage: { level: "ok", used_percent: 40.0 }
    }
  ],
  worker_health: { current: [{ hostname: "worker-1", health: { level: "ok", reasons: [] } }] }
}

describe("admin_version tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(adminVersionToolCard.toolName).toBe("admin_version")
  })

  it("summarizes the collapsed row with the live instance count", () => {
    expect(adminVersionToolCard.collapsedSummary?.(context({ parsedResult: HEALTHY_PAYLOAD }))).toBe("2 live instances")
  })

  it("flags mixed versions across instances (a deploy rollout in progress)", () => {
    const parsedResult = {
      ...HEALTHY_PAYLOAD,
      instances: [
        { hostname: "web-1", role: "web", version: "abc123" },
        { hostname: "web-2", role: "web", version: "def456" }
      ]
    }
    expect(adminVersionToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("2 live instances (mixed versions -- deploy in progress?)")
  })

  it("renders the handling host, instance table, and disk health", () => {
    render(<>{adminVersionToolCard.renderExpanded(context({ parsedResult: HEALTHY_PAYLOAD }))}</>)

    expect(screen.getAllByText("web-1").length).toBeGreaterThan(0)
    expect(screen.getByText("worker-1")).toBeInTheDocument()
    expect(screen.getByText("40.0%")).toBeInTheDocument()
    expect(screen.getAllByText("ok").length).toBeGreaterThan(0)
  })

  it("renders a critical disk level distinctly from ok", () => {
    const parsedResult = {
      ...HEALTHY_PAYLOAD,
      instances: [{ hostname: "worker-1", role: "worker", version: "abc123", data_root_usage: { level: "critical", used_percent: 97.2 } }]
    }

    render(<>{adminVersionToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("critical")).toBeInTheDocument()
    expect(screen.getByText("97.2%")).toBeInTheDocument()
  })

  it("renders an explicit empty state for no live instances", () => {
    const parsedResult = { request_handler: { hostname: "web-1" }, instances: [] }
    render(<>{adminVersionToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("No live instances found.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(adminVersionToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(adminVersionToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
