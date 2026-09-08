import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import readWorkerHealthToolCard from "./read_worker_health"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "read_worker_health",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const HEALTHY_PAYLOAD = {
  range: { since: "2026-09-05T00:00:00Z", until: "2026-09-06T00:00:00Z" },
  current: [
    {
      hostname: "worker-1",
      role: "worker",
      version: "abc123",
      stale: false,
      last_heartbeat_at: "2026-09-06T00:00:00Z",
      health: { level: "ok", reasons: [] },
      sample: { cpu_used_percent: 12.5, memory_used_percent: 40.0, data_root_used_percent: 30.0, io_pressure_some: 0.0 }
    }
  ],
  hosts: [
    { hostname: "worker-1", status: "current", windows: { "1h": { sample_count: 60, warning_count: 0, critical_count: 0 }, "24h": { sample_count: 1440, warning_count: 0, critical_count: 0 } } }
  ]
}

describe("read_worker_health tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(readWorkerHealthToolCard.toolName).toBe("read_worker_health")
  })

  it("summarizes a healthy fleet in the collapsed row", () => {
    expect(readWorkerHealthToolCard.collapsedSummary?.(context({ parsedResult: HEALTHY_PAYLOAD }))).toBe("1 worker healthy")
  })

  it("renders the current-worker table with pressure indicators and timing", () => {
    render(<>{readWorkerHealthToolCard.renderExpanded(context({ parsedResult: HEALTHY_PAYLOAD }))}</>)

    expect(screen.getAllByText("worker-1").length).toBeGreaterThan(0)
    expect(screen.getByText("12.5%")).toBeInTheDocument()
    expect(screen.getByText("40.0%")).toBeInTheDocument()
    expect(screen.getByText("2026-09-06T00:00:00Z")).toBeInTheDocument()
  })

  it("flags a stale, critical worker distinctly and summarizes it as needing attention", () => {
    const parsedResult = {
      ...HEALTHY_PAYLOAD,
      current: [
        {
          hostname: "worker-2",
          role: "worker",
          stale: true,
          last_heartbeat_at: "2026-09-05T23:00:00Z",
          health: { level: "critical", reasons: ["worker heartbeat stale", "CPU pressure critical"] },
          sample: null
        }
      ]
    }

    expect(readWorkerHealthToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("1 of 1 worker need attention")

    render(<>{readWorkerHealthToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("critical")).toBeInTheDocument()
    expect(screen.getByText("(stale)")).toBeInTheDocument()
  })

  it("renders per-host trend history behind a disclosure", () => {
    render(<>{readWorkerHealthToolCard.renderExpanded(context({ parsedResult: HEALTHY_PAYLOAD }))}</>)
    expect(screen.getByText("Host trend history")).toBeInTheDocument()
    expect(screen.getByText("60 samples")).toBeInTheDocument()
  })

  it("renders an explicit empty state for no live workers", () => {
    render(<>{readWorkerHealthToolCard.renderExpanded(context({ parsedResult: { range: HEALTHY_PAYLOAD.range, current: [], hosts: [] } }))}</>)
    expect(screen.getByText("No live workers found.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(readWorkerHealthToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(readWorkerHealthToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
